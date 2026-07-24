// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {FluentGovernance} from "../../contracts/governance/FluentGovernance.sol";
import {ChainConfig} from "../../contracts/staking/ChainConfig.sol";
import {IFluentGovernance} from "../../contracts/staking/interfaces/IFluentGovernance.sol";
import {IChainConfig} from "../../contracts/staking/interfaces/IChainConfig.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {IStakingPool} from "../../contracts/staking/interfaces/IStakingPool.sol";
import {ISystemReward} from "../../contracts/staking/interfaces/ISystemReward.sol";
import {Staking} from "../../contracts/staking/Staking.sol";
import {StakingPool} from "../../contracts/staking/StakingPool.sol";
import {SystemReward} from "../../contracts/staking/SystemReward.sol";
import {MockBlendToken} from "../../contracts/staking/mocks/MockBlendToken.sol";

contract FluentGovernanceTest is Test {
    uint256 internal constant ONE = 1 ether;

    Staking internal staking;
    ChainConfig internal chainConfig;
    FluentGovernance internal governance;
    MockBlendToken internal blend;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal validator1 = makeAddr("validator1");
    address internal validator2 = makeAddr("validator2");
    address internal owner1 = makeAddr("owner1");
    address internal owner2 = makeAddr("owner2");

    function setUp() public {
        blend = new MockBlendToken();
        _deploy(5);
    }

    function test_votingPowerFollowsValidatorOwners() public {
        assertEq(governance.getVotingSupply(), 2 * ONE);
        assertEq(governance.getVotingPower(validator1), ONE);
        assertEq(governance.getVotingPower(validator2), ONE);

        vm.prank(validator1);
        staking.changeValidatorOwner(validator1, owner1);
        vm.prank(validator2);
        staking.changeValidatorOwner(validator2, owner2);

        assertEq(governance.getVotingSupply(), 2 * ONE);
        assertEq(governance.getVotingPower(owner1), ONE);
        assertEq(governance.getVotingPower(owner2), ONE);
        assertEq(governance.getVotingPower(validator1), 0);
    }

    function test_ownerSwitchCannotDoubleVote() public {
        address[] memory targets = new address[](1);
        targets[0] = owner;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = hex"";

        vm.prank(validator1);
        uint256 proposalId = governance.propose(targets, values, calldatas, "empty proposal");

        vm.roll(block.number + 1);
        vm.prank(validator1);
        governance.castVote(proposalId, 1);
        assertEq(uint8(governance.state(proposalId)), uint8(IGovernor.ProposalState.Active));

        vm.prank(validator1);
        staking.changeValidatorOwner(validator1, owner1);

        vm.expectRevert();
        vm.prank(owner1);
        governance.castVote(proposalId, 1);

        vm.roll(block.number + governance.votingPeriod() + 1);
        assertEq(uint8(governance.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_customVotingPeriodAppliesToProposal() public {
        address[] memory targets = new address[](1);
        targets[0] = owner;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = hex"";

        vm.prank(validator1);
        uint256 proposalId = governance.proposeWithCustomVotingPeriod(targets, values, calldatas, "short proposal", 2);

        assertEq(governance.proposalDeadline(proposalId), governance.proposalSnapshot(proposalId) + 2);
        assertEq(governance.votingPeriod(), 5);
    }

    /// Audit 2b: with a non-zero DPoS activation, governance voting power must be read at
    /// the REBASED epoch and via the at-or-before snapshot — not the absolute epoch that
    /// would leak the validator's latest `changedAt` (future/latest) stake.
    function test_votingPowerUsesRebasedEpoch_notAbsolute() public {
        _deploy(1000, 100); // interval=50 ⇒ activation aligned; K = activation/interval = 2
        vm.roll(200); // rebased epoch = (200-100)/50 = 2

        uint256 snapBlock = block.number;
        assertEq(staking.getValidatorDelegatedStakeAt(validator1, snapBlock), ONE, "genesis power at snapshot");

        // validator1 delegates +ONE at epoch 2 ⇒ effective at epoch 4 (warmup): snapshot slot[4], changedAt=4.
        blend.mint(validator1, ONE);
        vm.startPrank(validator1);
        blend.approve(address(staking), ONE);
        staking.delegate(validator1, ONE);
        vm.stopPrank();

        // The historical read at `snapBlock` (epoch 2) must STILL be the genesis ONE:
        // the fresh stake is warming up and must not retroactively count.
        assertEq(
            staking.getValidatorDelegatedStakeAt(validator1, snapBlock),
            ONE,
            "historical power must exclude post-snapshot / warmup stake"
        );
    }

    /// Audit 2b end-to-end: a validator that delegates AFTER a proposal snapshot must not
    /// inflate its own vote weight on that proposal (per-timepoint snapshot preserved).
    function test_delegateAfterSnapshotCannotInflateVoteWeight() public {
        _deploy(1000, 100); // long voting period, activation=100, interval=50
        vm.roll(200); // rebased epoch 2

        address[] memory targets = new address[](1);
        targets[0] = owner;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = hex"";

        vm.prank(validator1);
        uint256 proposalId = governance.propose(targets, values, calldatas, "p"); // snapshot = block 200

        // Attempt to inflate weight by delegating more AFTER the snapshot.
        blend.mint(validator1, ONE);
        vm.startPrank(validator1);
        blend.approve(address(staking), ONE);
        staking.delegate(validator1, ONE);
        vm.stopPrank();

        vm.roll(block.number + 1); // enter Active voting window
        vm.prank(validator1);
        governance.castVote(proposalId, 1); // support = For

        (, uint256 forVotes,) = governance.proposalVotes(proposalId);
        assertEq(forVotes, ONE, "vote weight must use proposal-snapshot stake, not post-snapshot delegation");
    }

    function _deploy(uint32 votingPeriod) internal {
        _deploy(votingPeriod, uint64(0));
    }

    function _deploy(uint32 votingPeriod, uint64 dposActivationBlock) internal {
        uint64 nonce = vm.getNonce(address(this));
        IStaking predictedStaking = IStaking(vm.computeCreateAddress(address(this), nonce + 1));
        ISystemReward predictedSystemReward = ISystemReward(vm.computeCreateAddress(address(this), nonce + 3));
        IStakingPool predictedStakingPool = IStakingPool(vm.computeCreateAddress(address(this), nonce + 5));
        IChainConfig predictedChainConfig = IChainConfig(vm.computeCreateAddress(address(this), nonce + 7));
        IFluentGovernance predictedGovernance = IFluentGovernance(vm.computeCreateAddress(address(this), nonce + 9));

        address[] memory validators = new address[](2);
        validators[0] = validator1;
        validators[1] = validator2;
        uint256[] memory initialStakes = new uint256[](2);
        initialStakes[0] = ONE;
        initialStakes[1] = ONE;
        blend.mint(address(this), 2 * ONE);
        blend.approve(address(predictedStaking), 2 * ONE);

        Staking stakingImpl = new Staking(
            predictedStaking,
            predictedSystemReward,
            predictedStakingPool,
            predictedGovernance,
            predictedChainConfig,
            blend,
            address(0),
            address(0)
        );
        staking = Staking(
            payable(
                address(
                    new ERC1967Proxy(address(stakingImpl), abi.encodeCall(Staking.initialize, (address(this), validators, initialStakes, 0)))
                )
            )
        );

        address[] memory rewardAccounts = new address[](1);
        rewardAccounts[0] = treasury;
        uint16[] memory rewardShares = new uint16[](1);
        rewardShares[0] = 10_000;
        SystemReward systemRewardImpl = new SystemReward(
            predictedStaking,
            predictedSystemReward,
            predictedStakingPool,
            predictedGovernance,
            predictedChainConfig,
            blend
        );
        SystemReward systemReward = SystemReward(
            payable(
                address(
                    new ERC1967Proxy(
                        address(systemRewardImpl),
                        abi.encodeCall(SystemReward.initialize, (address(this), rewardAccounts, rewardShares))
                    )
                )
            )
        );

        StakingPool stakingPoolImpl = new StakingPool(
            predictedStaking,
            predictedSystemReward,
            predictedStakingPool,
            predictedGovernance,
            predictedChainConfig,
            blend
        );
        StakingPool stakingPool = StakingPool(
            payable(address(new ERC1967Proxy(address(stakingPoolImpl), abi.encodeCall(StakingPool.initialize, (address(this))))))
        );

        ChainConfig chainConfigImpl = new ChainConfig(
            predictedStaking,
            predictedSystemReward,
            predictedStakingPool,
            predictedGovernance,
            predictedChainConfig,
            blend
        );
        chainConfig = ChainConfig(
            address(
                new ERC1967Proxy(
                    address(chainConfigImpl),
                    abi.encodeCall(
                        ChainConfig.initialize,
                        (address(this), 3, 50, 150, 7, 1, ONE, ONE, dposActivationBlock, address(0), address(0), 0)
                    )
                )
            )
        );

        FluentGovernance governanceImpl = new FluentGovernance(predictedStaking, predictedChainConfig);
        governance = FluentGovernance(
            payable(
                address(new ERC1967Proxy(address(governanceImpl), abi.encodeCall(FluentGovernance.initialize, (address(this), votingPeriod))))
            )
        );

        assertEq(address(staking), address(predictedStaking));
        assertEq(address(systemReward), address(predictedSystemReward));
        assertEq(address(stakingPool), address(predictedStakingPool));
        assertEq(address(chainConfig), address(predictedChainConfig));
        assertEq(address(governance), address(predictedGovernance));
    }
}
