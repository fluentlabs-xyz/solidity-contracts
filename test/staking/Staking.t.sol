// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ChainConfig} from "../../contracts/staking/ChainConfig.sol";
import {SlashingIndicator} from "../../contracts/staking/SlashingIndicator.sol";
import {Staking} from "../../contracts/staking/Staking.sol";
import {StakingPool} from "../../contracts/staking/StakingPool.sol";
import {SystemReward} from "../../contracts/staking/SystemReward.sol";
import {IGovernance} from "../../contracts/staking/interfaces/IGovernance.sol";

contract StakingFoundryTest is Test {
    uint256 internal constant ONE = 1 ether;

    Staking internal staking;
    StakingPool internal stakingPool;
    ChainConfig internal chainConfig;
    SlashingIndicator internal slashingIndicator;
    SystemReward internal systemReward;

    address internal staker1 = makeAddr("staker1");
    address internal staker2 = makeAddr("staker2");
    address internal staker3 = makeAddr("staker3");
    address internal validator1 = makeAddr("validator1");
    address internal validator2 = makeAddr("validator2");
    address internal validator3 = makeAddr("validator3");
    address internal validator4 = makeAddr("validator4");

    function setUp() public {
        vm.deal(staker1, 1_000 ether);
        vm.deal(staker2, 1_000 ether);
        vm.deal(staker3, 1_000 ether);
        vm.deal(validator1, 1_000 ether);
        vm.deal(validator2, 1_000 ether);
        vm.deal(validator3, 1_000 ether);
        vm.deal(validator4, 1_000 ether);

        staking = new Staking();
        slashingIndicator = new SlashingIndicator();
        systemReward = new SystemReward();
        stakingPool = new StakingPool();
        chainConfig = new ChainConfig();

        staking.initialize(
            new address[](0),
            new uint256[](0),
            uint16(0),
            staking,
            slashingIndicator,
            systemReward,
            stakingPool,
            IGovernance(address(this)),
            chainConfig
        );
        slashingIndicator.initialize(
            staking, slashingIndicator, systemReward, stakingPool, IGovernance(address(this)), chainConfig
        );
        systemReward.initialize(
            _singleton(address(0)),
            _singleton16(10_000),
            staking,
            slashingIndicator,
            systemReward,
            stakingPool,
            IGovernance(address(this)),
            chainConfig
        );
        stakingPool.initialize(
            staking, slashingIndicator, systemReward, stakingPool, IGovernance(address(this)), chainConfig
        );
        chainConfig.initialize(
            uint32(3),
            uint32(10),
            uint32(50),
            uint32(150),
            uint32(7),
            uint32(0),
            uint256(ONE),
            uint256(ONE),
            staking,
            slashingIndicator,
            systemReward,
            stakingPool,
            IGovernance(address(this)),
            chainConfig
        );
    }

    function test_stakerCanDelegateToValidator() public {
        staking.addValidator(validator1);

        vm.prank(staker1);
        staking.delegate{value: ONE}(validator1);
        vm.prank(staker2);
        staking.delegate{value: ONE}(validator1);

        (uint256 staker1Delegated,) = staking.getValidatorDelegation(validator1, staker1);
        (uint256 staker2Delegated,) = staking.getValidatorDelegation(validator1, staker2);
        (, uint8 status, uint256 totalDelegated,,,,,,) = staking.getValidatorStatus(validator1);

        assertEq(staker1Delegated, ONE);
        assertEq(staker2Delegated, ONE);
        assertEq(totalDelegated, 2 * ONE);
        assertEq(status, 1);
    }

    function test_delegateAfterCommittedDelegationIncreasesAmount() public {
        staking.addValidator(validator1);

        vm.prank(staker1);
        staking.delegate{value: ONE}(validator1);
        _rollToNextEpoch();
        vm.prank(staker1);
        staking.delegate{value: ONE}(validator1);

        (uint256 delegated,) = staking.getValidatorDelegation(validator1, staker1);
        assertEq(delegated, 2 * ONE);
    }

    function test_undelegateUpdatesActiveSetAndClaimableFunds() public {
        staking.addValidator(validator1);
        staking.addValidator(validator2);

        vm.prank(staker1);
        staking.delegate{value: ONE}(validator1);
        vm.prank(staker2);
        staking.delegate{value: 2 * ONE}(validator2);

        address[] memory validators = staking.getValidators();
        assertEq(validators[0], validator2);
        assertEq(validators[1], validator1);

        vm.expectRevert("Staking: amount is too low");
        vm.prank(staker2);
        staking.undelegate(validator2, 1);

        vm.expectRevert("Staking: amount have a remainder");
        vm.prank(staker2);
        staking.undelegate(validator2, ONE + 1);

        vm.prank(staker2);
        staking.undelegate(validator2, ONE);

        (,, uint256 validator1Total,,,,,,) = staking.getValidatorStatus(validator1);
        (,, uint256 validator2Total,,,,,,) = staking.getValidatorStatus(validator2);
        assertEq(validator1Total, ONE);
        assertEq(validator2Total, ONE);

        validators = staking.getValidators();
        assertEq(validators[0], validator1);
        assertEq(validators[1], validator2);

        vm.prank(staker2);
        staking.undelegate(validator2, ONE);
        (uint256 delegated,) = staking.getValidatorDelegation(validator2, staker2);
        assertEq(delegated, 0);

        _rollToNextEpoch();
        assertEq(staking.getDelegatorFee(validator2, staker2), 2 * ONE);
    }

    function test_activeValidatorSetDependsOnDelegatedAmount() public {
        staking.addValidator(validator1);
        staking.addValidator(validator2);
        staking.addValidator(validator3);
        staking.addValidator(validator4);

        vm.prank(staker1);
        staking.delegate{value: 3 * ONE}(validator1);
        vm.prank(staker2);
        staking.delegate{value: 2 * ONE}(validator2);
        vm.prank(staker3);
        staking.delegate{value: ONE}(validator3);

        address[] memory validators = staking.getValidators();
        assertEq(validators.length, 3);
        assertEq(validators[0], validator1);
        assertEq(validators[1], validator2);
        assertEq(validators[2], validator3);

        vm.prank(staker3);
        staking.delegate{value: 4 * ONE}(validator4);

        validators = staking.getValidators();
        assertEq(validators.length, 3);
        assertEq(validators[0], validator4);
        assertEq(validators[1], validator1);
        assertEq(validators[2], validator2);
    }

    function test_RevertIf_delegateToUnknownValidator() public {
        staking.addValidator(validator1);
        staking.addValidator(validator3);

        vm.expectRevert("Staking: validator not found");
        vm.prank(staker1);
        staking.delegate{value: 3 * ONE}(validator2);
    }

    function test_stakingPoolTracksStakedAmount() public {
        staking.addValidator(validator1);

        vm.prank(staker1);
        stakingPool.stake{value: ONE}(validator1);
        vm.prank(staker1);
        stakingPool.stake{value: ONE}(validator1);
        vm.prank(staker2);
        stakingPool.stake{value: ONE}(validator1);

        assertEq(stakingPool.getStakedAmount(validator1, staker1), 2 * ONE);
        assertEq(stakingPool.getStakedAmount(validator1, staker2), ONE);
    }

    function test_stakingPoolClaimKeepsCompoundedRewards() public {
        staking.addValidator(validator1);

        vm.prank(staker1);
        stakingPool.stake{value: 50 * ONE}(validator1);
        assertEq(stakingPool.getStakedAmount(validator1, staker1), 50 * ONE);

        _rollToNextEpoch();
        vm.coinbase(validator1);
        vm.prank(validator1);
        staking.deposit{value: 101 * ONE / 100}(validator1);
        _rollToNextEpoch();

        assertEq(stakingPool.getStakedAmount(validator1, staker1), 51_009999999999999964);

        vm.prank(staker1);
        stakingPool.unstake(validator1, 50 * ONE);
        _rollToNextEpoch();

        vm.prank(staker1);
        stakingPool.claim(validator1);
        assertEq(stakingPool.getStakedAmount(validator1, staker1), 1_009999999999999999);
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
