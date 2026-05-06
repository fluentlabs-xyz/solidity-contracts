// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {Governance} from "../../contracts/governance/Governance.sol";
import {ChainConfig} from "../../contracts/staking/ChainConfig.sol";
import {IGovernance} from "../../contracts/staking/interfaces/IGovernance.sol";
import {IChainConfig} from "../../contracts/staking/interfaces/IChainConfig.sol";
import {ISlashingIndicator} from "../../contracts/staking/interfaces/ISlashingIndicator.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {IStakingPool} from "../../contracts/staking/interfaces/IStakingPool.sol";
import {ISystemReward} from "../../contracts/staking/interfaces/ISystemReward.sol";
import {SlashingIndicator} from "../../contracts/staking/SlashingIndicator.sol";
import {Staking} from "../../contracts/staking/Staking.sol";
import {StakingPool} from "../../contracts/staking/StakingPool.sol";
import {SystemReward} from "../../contracts/staking/SystemReward.sol";
import {MockBlendToken} from "../../contracts/staking/mocks/MockBlendToken.sol";

contract GovernanceTest is Test {
    uint256 internal constant ONE = 1 ether;

    Staking internal staking;
    ChainConfig internal chainConfig;
    Governance internal governance;
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

    function _deploy(uint32 votingPeriod) internal {
        uint64 nonce = vm.getNonce(address(this));
        IStaking predictedStaking = IStaking(vm.computeCreateAddress(address(this), nonce + 1));
        ISlashingIndicator predictedSlashingIndicator =
            ISlashingIndicator(vm.computeCreateAddress(address(this), nonce + 3));
        ISystemReward predictedSystemReward = ISystemReward(vm.computeCreateAddress(address(this), nonce + 5));
        IStakingPool predictedStakingPool = IStakingPool(vm.computeCreateAddress(address(this), nonce + 7));
        IChainConfig predictedChainConfig = IChainConfig(vm.computeCreateAddress(address(this), nonce + 9));
        IGovernance predictedGovernance = IGovernance(vm.computeCreateAddress(address(this), nonce + 11));

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
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            predictedGovernance,
            predictedChainConfig,
            blend
        );
        staking = Staking(
            payable(address(
                    new ERC1967Proxy(
                        address(stakingImpl),
                        abi.encodeCall(Staking.initialize, (address(this), validators, initialStakes, 0))
                    )
                ))
        );

        SlashingIndicator slashingIndicatorImpl = new SlashingIndicator(
            predictedStaking,
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            predictedGovernance,
            predictedChainConfig,
            blend
        );
        SlashingIndicator slashingIndicator = SlashingIndicator(
            address(
                new ERC1967Proxy(
                    address(slashingIndicatorImpl), abi.encodeCall(SlashingIndicator.initialize, (address(this)))
                )
            )
        );

        address[] memory rewardAccounts = new address[](1);
        rewardAccounts[0] = treasury;
        uint16[] memory rewardShares = new uint16[](1);
        rewardShares[0] = 10_000;
        SystemReward systemRewardImpl = new SystemReward(
            predictedStaking,
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            predictedGovernance,
            predictedChainConfig,
            blend
        );
        SystemReward systemReward = SystemReward(
            payable(address(
                    new ERC1967Proxy(
                        address(systemRewardImpl),
                        abi.encodeCall(SystemReward.initialize, (address(this), rewardAccounts, rewardShares))
                    )
                ))
        );

        StakingPool stakingPoolImpl = new StakingPool(
            predictedStaking,
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            predictedGovernance,
            predictedChainConfig,
            blend
        );
        StakingPool stakingPool = StakingPool(
            payable(address(
                    new ERC1967Proxy(address(stakingPoolImpl), abi.encodeCall(StakingPool.initialize, (address(this))))
                ))
        );

        ChainConfig chainConfigImpl = new ChainConfig(
            predictedStaking,
            predictedSlashingIndicator,
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
                    abi.encodeCall(ChainConfig.initialize, (address(this), 3, 50, 50, 150, 7, 0, ONE, ONE))
                )
            )
        );

        Governance governanceImpl = new Governance(predictedStaking, predictedChainConfig);
        governance = Governance(
            payable(address(
                    new ERC1967Proxy(
                        address(governanceImpl), abi.encodeCall(Governance.initialize, (address(this), votingPeriod))
                    )
                ))
        );

        assertEq(address(staking), address(predictedStaking));
        assertEq(address(slashingIndicator), address(predictedSlashingIndicator));
        assertEq(address(systemReward), address(predictedSystemReward));
        assertEq(address(stakingPool), address(predictedStakingPool));
        assertEq(address(chainConfig), address(predictedChainConfig));
        assertEq(address(governance), address(predictedGovernance));
    }
}
