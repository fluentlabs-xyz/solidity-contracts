// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IStakingContextErrors} from "../../contracts/staking/interfaces/IStakingContext.sol";
import {ChainConfig} from "../../contracts/staking/ChainConfig.sol";
import {SlashingIndicator} from "../../contracts/staking/SlashingIndicator.sol";
import {Staking} from "../../contracts/staking/Staking.sol";
import {StakingPool} from "../../contracts/staking/StakingPool.sol";
import {SystemReward} from "../../contracts/staking/SystemReward.sol";
import {MockBlendToken} from "../../contracts/staking/mocks/MockBlendToken.sol";
import {IChainConfig} from "../../contracts/staking/interfaces/IChainConfig.sol";
import {IFluentGovernance} from "../../contracts/staking/interfaces/IFluentGovernance.sol";
import {ISlashingIndicator} from "../../contracts/staking/interfaces/ISlashingIndicator.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {IStakingPool} from "../../contracts/staking/interfaces/IStakingPool.sol";
import {ISystemReward} from "../../contracts/staking/interfaces/ISystemReward.sol";

contract StakingFoundryTest is Test {
    uint256 internal constant ONE = 1 ether;

    Staking internal staking;
    StakingPool internal stakingPool;
    ChainConfig internal chainConfig;
    SlashingIndicator internal slashingIndicator;
    SystemReward internal systemReward;
    MockBlendToken internal blend;

    address internal staker1 = makeAddr("staker1");
    address internal staker2 = makeAddr("staker2");
    address internal staker3 = makeAddr("staker3");
    address internal validator1 = makeAddr("validator1");
    address internal validator2 = makeAddr("validator2");
    address internal validator3 = makeAddr("validator3");
    address internal validator4 = makeAddr("validator4");

    function setUp() public {
        blend = new MockBlendToken();
        _fund(staker1);
        _fund(staker2);
        _fund(staker3);
        _fund(validator1);
        _fund(validator2);
        _fund(validator3);
        _fund(validator4);

        uint64 nonce = vm.getNonce(address(this));
        IStaking predictedStaking = IStaking(vm.computeCreateAddress(address(this), nonce + 1));
        ISlashingIndicator predictedSlashingIndicator =
            ISlashingIndicator(vm.computeCreateAddress(address(this), nonce + 3));
        ISystemReward predictedSystemReward = ISystemReward(vm.computeCreateAddress(address(this), nonce + 5));
        IStakingPool predictedStakingPool = IStakingPool(vm.computeCreateAddress(address(this), nonce + 7));
        IChainConfig predictedChainConfig = IChainConfig(vm.computeCreateAddress(address(this), nonce + 9));
        IFluentGovernance governance = IFluentGovernance(address(this));

        Staking stakingImpl = new Staking(
            predictedStaking,
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig,
            blend
        );
        staking = Staking(
            payable(address(
                    new ERC1967Proxy(
                        address(stakingImpl),
                        abi.encodeCall(
                            Staking.initialize, (address(this), new address[](0), new uint256[](0), uint16(0))
                        )
                    )
                ))
        );

        SlashingIndicator slashingIndicatorImpl = new SlashingIndicator(
            predictedStaking,
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig,
            blend
        );
        slashingIndicator = SlashingIndicator(
            address(
                new ERC1967Proxy(
                    address(slashingIndicatorImpl), abi.encodeCall(SlashingIndicator.initialize, (address(this)))
                )
            )
        );

        SystemReward systemRewardImpl = new SystemReward(
            predictedStaking,
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig,
            blend
        );
        systemReward = SystemReward(
            payable(address(
                    new ERC1967Proxy(
                        address(systemRewardImpl),
                        abi.encodeCall(
                            SystemReward.initialize, (address(this), _singleton(address(0)), _singleton16(10_000))
                        )
                    )
                ))
        );

        StakingPool stakingPoolImpl = new StakingPool(
            predictedStaking,
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig,
            blend
        );
        stakingPool = StakingPool(
            payable(address(
                    new ERC1967Proxy(address(stakingPoolImpl), abi.encodeCall(StakingPool.initialize, (address(this))))
                ))
        );

        ChainConfig chainConfigImpl = new ChainConfig(
            predictedStaking,
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig,
            blend
        );
        chainConfig = ChainConfig(
            address(
                new ERC1967Proxy(
                    address(chainConfigImpl),
                    abi.encodeCall(
                        ChainConfig.initialize,
                        (
                            address(this),
                            uint32(3),
                            uint32(10),
                            uint32(50),
                            uint32(150),
                            uint32(7),
                            uint32(1),
                            uint256(ONE),
                            uint256(ONE)
                        )
                    )
                )
            )
        );

        assertEq(address(staking), address(predictedStaking));
        assertEq(address(slashingIndicator), address(predictedSlashingIndicator));
        assertEq(address(systemReward), address(predictedSystemReward));
        assertEq(address(stakingPool), address(predictedStakingPool));
        assertEq(address(chainConfig), address(predictedChainConfig));

        _approveAll(staker1);
        _approveAll(staker2);
        _approveAll(staker3);
        _approveAll(validator1);
        _approveAll(validator2);
        _approveAll(validator3);
        _approveAll(validator4);
    }

    function test_stakerCanDelegateToValidator() public {
        staking.addValidator(validator1);

        uint256 staker1BalanceBefore = blend.balanceOf(staker1);
        vm.prank(staker1);
        staking.delegate(validator1, ONE);
        vm.prank(staker2);
        staking.delegate(validator1, ONE);

        (uint256 staker1Delegated,) = staking.getValidatorDelegation(validator1, staker1);
        (uint256 staker2Delegated,) = staking.getValidatorDelegation(validator1, staker2);
        (, uint8 status, uint256 totalDelegated,,,,,,) = staking.getValidatorStatus(validator1);

        assertEq(staker1Delegated, ONE);
        assertEq(staker2Delegated, ONE);
        assertEq(totalDelegated, 2 * ONE);
        assertEq(status, 1);
        assertEq(blend.balanceOf(staker1), staker1BalanceBefore - ONE);
        assertEq(blend.balanceOf(address(staking)), 2 * ONE);
    }

    function test_delegateAfterCommittedDelegationIncreasesAmount() public {
        staking.addValidator(validator1);

        vm.prank(staker1);
        staking.delegate(validator1, ONE);
        _rollToNextEpoch();
        vm.prank(staker1);
        staking.delegate(validator1, ONE);

        (uint256 delegated,) = staking.getValidatorDelegation(validator1, staker1);
        assertEq(delegated, 2 * ONE);
    }

    function test_undelegateUpdatesActiveSetAndClaimableFunds() public {
        staking.addValidator(validator1);
        staking.addValidator(validator2);

        vm.prank(staker1);
        staking.delegate(validator1, ONE);
        vm.prank(staker2);
        staking.delegate(validator2, 2 * ONE);
        _rollToNextEpoch();

        address[] memory validators = staking.getValidators();
        assertEq(validators[0], validator2);
        assertEq(validators[1], validator1);

        vm.expectRevert(abi.encodeWithSelector(IStakingContextErrors.AmountTooLow.selector, 1));
        vm.prank(staker2);
        staking.undelegate(validator2, 1);

        vm.expectRevert(IStakingContextErrors.WrongAmountPrecision.selector);
        vm.prank(staker2);
        staking.undelegate(validator2, ONE + 1);

        vm.prank(staker2);
        staking.undelegate(validator2, ONE);

        (,, uint256 validator1Total,,,,,,) = staking.getValidatorStatus(validator1);
        (,, uint256 validator2Total,,,,,,) = staking.getValidatorStatus(validator2);
        assertEq(validator1Total, ONE);
        assertEq(validator2Total, ONE);

        validators = staking.getValidators();
        assertEq(validators[0], validator2);
        assertEq(validators[1], validator1);
        _rollToNextEpoch();
        validators = staking.getValidators();
        assertEq(validators[0], validator1);
        assertEq(validators[1], validator2);

        vm.prank(staker2);
        staking.undelegate(validator2, ONE);
        (uint256 delegated,) = staking.getValidatorDelegation(validator2, staker2);
        assertEq(delegated, 0);

        _rollToNextEpoch();
        _rollToNextEpoch();
        assertEq(staking.getDelegatorFee(validator2, staker2), 2 * ONE);
    }

    function test_activeValidatorSetDependsOnDelegatedAmount() public {
        staking.addValidator(validator1);
        staking.addValidator(validator2);
        staking.addValidator(validator3);
        staking.addValidator(validator4);

        vm.prank(staker1);
        staking.delegate(validator1, 3 * ONE);
        vm.prank(staker2);
        staking.delegate(validator2, 2 * ONE);
        vm.prank(staker3);
        staking.delegate(validator3, ONE);
        _rollToNextEpoch();

        address[] memory validators = staking.getValidators();
        assertEq(validators.length, 3);
        assertEq(validators[0], validator1);
        assertEq(validators[1], validator2);
        assertEq(validators[2], validator3);

        vm.prank(staker3);
        staking.delegate(validator4, 4 * ONE);

        validators = staking.getValidators();
        assertEq(validators.length, 3);
        assertEq(validators[0], validator1);
        assertEq(validators[1], validator2);
        assertEq(validators[2], validator3);
        _rollToNextEpoch();

        validators = staking.getValidators();
        assertEq(validators.length, 3);
        assertEq(validators[0], validator4);
        assertEq(validators[1], validator1);
        assertEq(validators[2], validator2);
    }

    function test_RevertIf_delegateToUnknownValidator() public {
        staking.addValidator(validator1);
        staking.addValidator(validator3);

        vm.expectRevert(abi.encodeWithSelector(IStakingContextErrors.ValidatorNotFound.selector, validator2));
        vm.prank(staker1);
        staking.delegate(validator2, 3 * ONE);
    }

    function test_stakingPoolTracksStakedAmount() public {
        staking.addValidator(validator1);

        vm.prank(staker1);
        stakingPool.stake(validator1, ONE);
        vm.prank(staker1);
        stakingPool.stake(validator1, ONE);
        vm.prank(staker2);
        stakingPool.stake(validator1, ONE);

        assertEq(stakingPool.getStakedAmount(validator1, staker1), 2 * ONE);
        assertEq(stakingPool.getStakedAmount(validator1, staker2), ONE);
    }

    function test_stakingPoolClaimKeepsCompoundedRewards() public {
        staking.addValidator(validator1);

        vm.prank(staker1);
        stakingPool.stake(validator1, 50 * ONE);
        assertEq(stakingPool.getStakedAmount(validator1, staker1), 50 * ONE);

        _rollToNextEpoch();
        vm.coinbase(validator1);
        vm.prank(validator1);
        staking.deposit(validator1, (101 * ONE) / 100);
        _rollToNextEpoch();

        assertEq(stakingPool.getStakedAmount(validator1, staker1), 51_009999999999999979);

        vm.prank(staker1);
        stakingPool.unstake(validator1, 50 * ONE);
        _rollToNextEpoch();
        _rollToNextEpoch();

        vm.prank(staker1);
        stakingPool.claim(validator1);
        assertEq(stakingPool.getStakedAmount(validator1, staker1), 1_009999999999999979);
    }

    function _fund(address account) internal {
        blend.mint(account, 1_000_000 ether);
    }

    function _approveAll(address account) internal {
        vm.startPrank(account);
        blend.approve(address(staking), type(uint256).max);
        blend.approve(address(stakingPool), type(uint256).max);
        vm.stopPrank();
    }

    function _rollToNextEpoch() internal {
        uint64 nextEpoch = staking.nextEpoch();
        vm.roll(uint256(nextEpoch) * chainConfig.getEpochBlockInterval());
    }

    function _singleton(address value) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _singleton16(uint16 value) internal pure returns (uint16[] memory values) {
        values = new uint16[](1);
        values[0] = value;
    }
}
