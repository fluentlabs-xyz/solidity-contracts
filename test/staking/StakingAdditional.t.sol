// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ChainConfig} from "../../contracts/staking/ChainConfig.sol";
import {IChainConfig} from "../../contracts/staking/interfaces/IChainConfig.sol";
import {IGovernance} from "../../contracts/staking/interfaces/IGovernance.sol";
import {ISlashingIndicator} from "../../contracts/staking/interfaces/ISlashingIndicator.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {IStakingPool} from "../../contracts/staking/interfaces/IStakingPool.sol";
import {ISystemReward} from "../../contracts/staking/interfaces/ISystemReward.sol";
import {SlashingIndicator} from "../../contracts/staking/SlashingIndicator.sol";
import {Staking} from "../../contracts/staking/Staking.sol";
import {StakingErrors} from "../../contracts/staking/StakingErrors.sol";
import {StakingPool} from "../../contracts/staking/StakingPool.sol";
import {SystemReward} from "../../contracts/staking/SystemReward.sol";

contract StakingAdditionalTest is Test {
    uint256 internal constant ONE = 1 ether;

    Staking internal staking;
    StakingPool internal stakingPool;
    ChainConfig internal chainConfig;
    SlashingIndicator internal slashingIndicator;
    SystemReward internal systemReward;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal staker1 = makeAddr("staker1");
    address internal staker2 = makeAddr("staker2");
    address internal validator1 = makeAddr("validator1");
    address internal validator2 = makeAddr("validator2");
    address internal validator3 = makeAddr("validator3");

    function setUp() public {
        vm.deal(owner, 1_000 ether);
        vm.deal(treasury, 1_000 ether);
        vm.deal(staker1, 1_000 ether);
        vm.deal(staker2, 1_000 ether);
        vm.deal(validator1, 1_000 ether);
        vm.deal(validator2, 1_000 ether);
        vm.deal(validator3, 1_000 ether);
        _deploy(
            10, 50, 150, 7, 0, ONE, ONE, _emptyAddresses(), _emptyUint256s(), _singleton(treasury), _singleton16(10_000)
        );
    }

    function test_canAddAndRemoveValidator() public {
        assertEq(address(staking.getStaking()), address(staking));
        assertEq(address(staking.getSlashingIndicator()), address(slashingIndicator));
        assertEq(address(staking.getSystemReward()), address(systemReward));
        assertEq(address(staking.getStakingPool()), address(stakingPool));
        assertEq(address(staking.getGovernance()), address(this));
        assertEq(address(staking.getChainConfig()), address(chainConfig));

        assertFalse(staking.isValidator(validator1));
        staking.addValidator(validator1);
        assertTrue(staking.isValidator(validator1));
        assertEq(staking.getValidators().length, 1);
        assertEq(staking.getValidators()[0], validator1);

        staking.removeValidator(validator1);
        assertFalse(staking.isValidator(validator1));
        assertEq(staking.getValidators().length, 0);
    }

    function test_ownerControlsUUPSUpgrade() public {
        assertEq(staking.owner(), address(this));
        assertEq(slashingIndicator.owner(), address(this));
        assertEq(systemReward.owner(), address(this));
        assertEq(stakingPool.owner(), address(this));
        assertEq(chainConfig.owner(), address(this));

        uint64 nonce = vm.getNonce(address(this));
        Staking predictedProxy = Staking(vm.computeCreateAddress(address(this), nonce + 1));
        Staking implementation = new Staking(
            predictedProxy,
            ISlashingIndicator(address(predictedProxy)),
            ISystemReward(address(predictedProxy)),
            IStakingPool(address(predictedProxy)),
            IGovernance(address(this)),
            IChainConfig(address(predictedProxy))
        );
        Staking proxy = Staking(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(Staking.initialize, (address(this), _emptyAddresses(), _emptyUint256s(), uint16(0)))
                )
            )
        );
        Staking upgradedImplementation = new Staking(
            proxy,
            ISlashingIndicator(address(proxy)),
            ISystemReward(address(proxy)),
            IStakingPool(address(proxy)),
            IGovernance(address(this)),
            IChainConfig(address(proxy))
        );

        assertEq(address(proxy), address(predictedProxy));
        assertEq(proxy.owner(), address(this));

        vm.expectRevert();
        vm.prank(staker1);
        proxy.upgradeToAndCall(address(upgradedImplementation), "");

        proxy.upgradeToAndCall(address(upgradedImplementation), "");
        assertEq(proxy.owner(), address(this));
    }

    function test_chainConfigGovernanceSetters() public {
        chainConfig.setActiveValidatorsLength(5);
        chainConfig.setEpochBlockInterval(11);
        chainConfig.setMisdemeanorThreshold(51);
        chainConfig.setFelonyThreshold(151);
        chainConfig.setValidatorJailEpochLength(8);
        chainConfig.setUndelegatePeriod(2);
        chainConfig.setMinValidatorStakeAmount(2 * ONE);
        chainConfig.setMinStakingAmount(3 * ONE);

        assertEq(chainConfig.getActiveValidatorsLength(), 5);
        assertEq(chainConfig.getEpochBlockInterval(), 11);
        assertEq(chainConfig.getMisdemeanorThreshold(), 51);
        assertEq(chainConfig.getFelonyThreshold(), 151);
        assertEq(chainConfig.getValidatorJailEpochLength(), 8);
        assertEq(chainConfig.getUndelegatePeriod(), 2);
        assertEq(chainConfig.getMinValidatorStakeAmount(), 2 * ONE);
        assertEq(chainConfig.getMinStakingAmount(), 3 * ONE);

        vm.expectRevert(StakingErrors.OnlyGovernance.selector);
        vm.prank(staker1);
        chainConfig.setActiveValidatorsLength(6);
    }

    function test_statusAndDelegationViewsForEmptyAndHistoricalEpochs() public {
        (uint256 delegated, uint64 atEpoch) = staking.getValidatorDelegation(validator1, staker1);
        assertEq(delegated, 0);
        assertEq(atEpoch, 0);

        staking.addValidator(validator1);
        vm.prank(staker1);
        staking.delegate{value: ONE}(validator1);
        _rollToNextEpoch();

        (,, uint256 historicalDelegated,,,,,,) = staking.getValidatorStatusAtEpoch(validator1, staking.currentEpoch());
        assertEq(historicalDelegated, ONE);
        assertTrue(staking.isValidatorActive(validator1));
        assertFalse(staking.isValidatorActive(validator2));
        assertEq(staking.getPendingValidatorFee(validator2), 0);
    }

    function test_removeValidatorFromBeginningMiddleAndEnd() public {
        staking.addValidator(address(1));
        staking.addValidator(address(2));
        staking.addValidator(address(3));

        staking.removeValidator(address(1));
        assertEq(staking.getValidators().length, 2);
        assertTrue(staking.isValidator(address(2)));
        assertTrue(staking.isValidator(address(3)));

        _deploy(
            10, 50, 150, 7, 0, ONE, ONE, _emptyAddresses(), _emptyUint256s(), _singleton(treasury), _singleton16(10_000)
        );
        staking.addValidator(address(1));
        staking.addValidator(address(2));
        staking.addValidator(address(3));
        staking.removeValidator(address(2));
        assertEq(staking.getValidators().length, 2);
        assertTrue(staking.isValidator(address(1)));
        assertTrue(staking.isValidator(address(3)));

        _deploy(
            10, 50, 150, 7, 0, ONE, ONE, _emptyAddresses(), _emptyUint256s(), _singleton(treasury), _singleton16(10_000)
        );
        staking.addValidator(address(1));
        staking.addValidator(address(2));
        staking.addValidator(address(3));
        staking.removeValidator(address(3));
        assertEq(staking.getValidators().length, 2);
        assertTrue(staking.isValidator(address(1)));
        assertTrue(staking.isValidator(address(2)));
    }

    function test_userCanUndelegateAfterUndelegate() public {
        staking.addValidator(validator1);
        vm.prank(staker1);
        staking.delegate{value: 3 * ONE}(validator1);
        _rollToNextEpoch();

        vm.prank(staker1);
        staking.undelegate(validator1, ONE);
        vm.prank(staker1);
        staking.undelegate(validator1, ONE);
        _rollToNextEpoch();
        vm.prank(staker1);
        staking.undelegate(validator1, ONE);

        (,, uint256 totalDelegated,,,,,,) = staking.getValidatorStatus(validator1);
        assertEq(totalDelegated, 0);
        _rollToNextEpoch();
        assertEq(staking.getDelegatorFee(validator1, staker1), 3 * ONE);
    }

    function test_RevertIf_undelegateMoreThanDelegated() public {
        staking.addValidator(validator1);
        vm.prank(staker1);
        staking.delegate{value: ONE}(validator1);
        vm.prank(staker1);
        staking.delegate{value: 2 * ONE}(validator1);
        vm.prank(staker1);
        staking.delegate{value: 3 * ONE}(validator1);

        vm.prank(staker1);
        staking.undelegate(validator1, 5 * ONE);
        vm.expectRevert(StakingErrors.InsufficientBalance.selector);
        vm.prank(staker1);
        staking.undelegate(validator1, 2 * ONE);
        vm.prank(staker1);
        staking.undelegate(validator1, ONE);
        _rollToNextEpoch();
        assertEq(staking.getDelegatorFee(validator1, staker1), 6 * ONE);
    }

    function test_validatorCanClaimCommissionAndDelegatorRewards() public {
        vm.prank(validator1);
        staking.registerValidator{value: ONE}(validator1, 3000);
        staking.activateValidator(validator1);
        _rollToNextEpoch();

        _depositReward(validator1, ONE);
        _rollToNextEpoch();
        _depositReward(validator1, ONE);
        _rollToNextEpoch();

        assertEq(staking.getDelegatorFee(validator1, validator1), 14 * ONE / 10);
        assertEq(staking.getValidatorFee(validator1), 6 * ONE / 10);
    }

    function test_stakerRewardsWithMultipleDelegations() public {
        vm.prank(validator1);
        staking.registerValidator{value: 2 * ONE}(validator1, 1000);
        staking.activateValidator(validator1);
        _rollToNextEpoch();

        vm.prank(staker1);
        staking.delegate{value: ONE}(validator1);
        _rollToNextEpoch();
        vm.prank(staker1);
        staking.delegate{value: ONE}(validator1);
        _rollToNextEpoch();

        _depositReward(validator1, ONE / 2);
        _rollToNextEpoch();
        _depositReward(validator1, ONE / 2);
        _rollToNextEpoch();

        assertEq(staking.getValidatorFee(validator1), ONE / 10);
        assertEq(staking.getDelegatorFee(validator1, validator1), 45 * ONE / 100);
        assertEq(staking.getDelegatorFee(validator1, staker1), 45 * ONE / 100);
    }

    function test_onlyCommittedEpochIsClaimable() public {
        vm.prank(validator1);
        staking.registerValidator{value: 2 * ONE}(validator1, 1000);
        staking.activateValidator(validator1);
        _rollToNextEpoch();

        _depositReward(validator1, ONE);
        _rollToNextEpoch();
        _depositReward(validator1, ONE);

        assertEq(staking.getValidatorFee(validator1), ONE / 10);
        assertEq(staking.getDelegatorFee(validator1, validator1), 9 * ONE / 10);
    }

    function test_validatorWithoutDelegatorsGetsAllRewards() public {
        staking.addValidator(validator1);
        vm.prank(validator1);
        staking.changeValidatorCommissionRate(validator1, 1000);
        _rollToNextEpoch();

        _depositReward(validator1, ONE);
        _rollToNextEpoch();

        assertEq(staking.getValidatorFee(validator1), ONE);
    }

    function test_validatorRewardsAreWellCalculated() public {
        staking.addValidator(validator1);
        vm.prank(validator1);
        staking.changeValidatorCommissionRate(validator1, 30);
        vm.prank(staker1);
        staking.delegate{value: ONE}(validator1);
        _rollToNextEpoch();

        vm.expectRevert(StakingErrors.DepositIsZero.selector);
        _depositReward(validator1, 0);
        vm.expectRevert(StakingErrors.ValidatorNotFound.selector);
        _depositReward(validator3, ONE);

        _depositReward(validator1, ONE);
        _depositReward(validator1, ONE / 10);
        _depositReward(validator1, ONE / 100);
        _depositReward(validator1, ONE / 1_000);
        _depositReward(validator1, ONE / 10_000);
        _rollToNextEpoch();

        assertEq(staking.getValidatorFee(validator1), 3_333_300_000_000_000);
        assertEq(staking.getDelegatorFee(validator1, staker1), 1_107_766_700_000_000_000);

        _rollToNextEpoch();
        assertEq(staking.getValidatorFee(validator1), 3_333_300_000_000_000);
        assertEq(staking.getDelegatorFee(validator1, staker1), 1_107_766_700_000_000_000);

        vm.prank(staker1);
        staking.claimDelegatorFee(validator1);
        assertEq(staking.getDelegatorFee(validator1, staker1), 0);
        assertEq(staking.getValidatorFee(validator1), 3_333_300_000_000_000);
    }

    function test_noValidatorRewardsForInactivitySlashOnly() public {
        _deploy(
            50, 5, 10, 7, 0, ONE, ONE, _emptyAddresses(), _emptyUint256s(), _singleton(treasury), _singleton16(10_000)
        );
        staking.addValidator(validator1);
        staking.addValidator(validator2);
        for (uint256 i = 0; i < 5; i++) {
            _slash(validator2);
        }
        _rollToNextEpoch();
        assertEq(staking.getValidatorFee(validator1), 0);
    }

    function test_incorrectStakingAmounts() public {
        _deploy(
            10, 50, 150, 7, 0, 0, 0, _emptyAddresses(), _emptyUint256s(), _singleton(treasury), _singleton16(10_000)
        );
        staking.addValidator(validator1);

        vm.prank(staker1);
        staking.delegate{value: 1e10}(validator1);
        vm.expectRevert(StakingErrors.WrongAmountPrecision.selector);
        vm.prank(staker1);
        staking.delegate{value: 1e9}(validator1);
        vm.expectRevert(StakingErrors.AmountTooLow.selector);
        vm.prank(staker1);
        staking.delegate{value: 0}(validator1);
        vm.expectRevert(StakingErrors.WrongAmountPrecision.selector);
        vm.prank(staker1);
        staking.delegate{value: ONE + 1e9}(validator1);
    }

    function test_putValidatorInJailAfterFelonyThreshold() public {
        _deploy(
            300, 10, 20, 7, 0, ONE, ONE, _emptyAddresses(), _emptyUint256s(), _singleton(treasury), _singleton16(10_000)
        );
        staking.addValidator(validator1);
        staking.addValidator(validator2);

        for (uint256 i = 0; i < 19; i++) {
            _slash(validator2);
        }
        (, uint8 statusBefore,,,,,,,) = staking.getValidatorStatus(validator2);
        assertEq(statusBefore, 1);

        _slash(validator2);
        (, uint8 statusAfter,,,,,,,) = staking.getValidatorStatus(validator2);
        assertEq(statusAfter, 3);
    }

    function test_validatorCanBeReleasedFromJailByOwner() public {
        _deploy(
            50, 10, 5, 2, 0, ONE, ONE, _emptyAddresses(), _emptyUint256s(), _singleton(treasury), _singleton16(10_000)
        );
        staking.addValidator(validator1);
        staking.addValidator(validator2);

        vm.expectRevert(StakingErrors.ValidatorNotInJail.selector);
        vm.prank(validator1);
        staking.releaseValidatorFromJail(validator2);

        _rollToNextEpoch();
        for (uint256 i = 0; i < 5; i++) {
            _slash(validator2);
        }
        (, uint8 jailedStatus,, uint32 slashes,,,,,) = staking.getValidatorStatus(validator2);
        assertEq(slashes, 5);
        assertEq(jailedStatus, 3);

        vm.expectRevert(StakingErrors.StillInJail.selector);
        vm.prank(validator2);
        staking.releaseValidatorFromJail(validator2);

        _rollToNextEpoch();
        _rollToNextEpoch();
        vm.expectRevert(StakingErrors.OnlyValidatorOwner.selector);
        vm.prank(validator1);
        staking.releaseValidatorFromJail(validator2);
        vm.prank(validator2);
        staking.releaseValidatorFromJail(validator2);
        (, uint8 activeStatus,,,,,,,) = staking.getValidatorStatus(validator2);
        assertEq(activeStatus, 1);
    }

    function test_validatorCanUndelegateInitialStake() public {
        vm.prank(validator1);
        staking.registerValidator{value: 10 * ONE}(validator1, 1000);
        _rollToNextEpoch();

        (uint256 delegated,) = staking.getValidatorDelegation(validator1, validator1);
        assertEq(delegated, 10 * ONE);
        vm.prank(validator1);
        staking.undelegate(validator1, 10 * ONE);
        _rollToNextEpoch();

        assertEq(staking.getDelegatorFee(validator1, validator1), 10 * ONE);
        (delegated,) = staking.getValidatorDelegation(validator1, validator1);
        assertEq(delegated, 0);
    }

    function test_validatorOwnerCanChangeOwnerAndCommission() public {
        staking.addValidator(validator1);
        assertEq(staking.getValidatorByOwner(validator1), validator1);

        vm.expectRevert(StakingErrors.OnlyValidatorOwner.selector);
        vm.prank(validator2);
        staking.changeValidatorOwner(validator1, owner);
        vm.prank(validator1);
        staking.changeValidatorOwner(validator1, owner);
        assertEq(staking.getValidatorByOwner(owner), validator1);

        vm.expectRevert(StakingErrors.OnlyValidatorOwner.selector);
        vm.prank(validator2);
        staking.changeValidatorCommissionRate(validator1, 0);
    }

    function test_disableValidatorAndPendingRewardViews() public {
        staking.addValidator(validator1);
        vm.prank(staker1);
        staking.delegate{value: ONE}(validator1);
        _rollToNextEpoch();
        _depositReward(validator1, ONE);

        assertEq(staking.getPendingDelegatorFee(validator1, staker1), ONE);
        assertEq(staking.getPendingValidatorFee(validator1), 0);

        staking.disableValidator(validator1);
        (, uint8 status,,,,,,,) = staking.getValidatorStatus(validator1);
        assertEq(status, 2);
        assertFalse(staking.isValidatorActive(validator1));

        vm.expectRevert(StakingErrors.NotActiveValidator.selector);
        staking.disableValidator(validator1);
    }

    function test_epochBoundedClaimsAndUnsafeTransferPath() public {
        staking.addValidator(validator1);
        _rollToNextEpoch();
        _depositReward(validator1, ONE);
        _rollToNextEpoch();

        uint64 epoch = staking.currentEpoch();
        vm.prank(validator1);
        staking.claimValidatorFeeAtEpoch(validator1, epoch);

        vm.expectRevert(StakingErrors.OnlyValidatorOwner.selector);
        vm.prank(staker1);
        staking.claimValidatorFee(validator1);

        epoch = staking.currentEpoch();
        vm.expectRevert();
        vm.prank(validator1);
        staking.claimValidatorFeeAtEpoch(validator1, epoch + 1);

        epoch = staking.currentEpoch();
        vm.prank(validator1);
        staking.claimDelegatorFeeAtEpoch(validator1, epoch);
        epoch = staking.currentEpoch();
        vm.expectRevert();
        vm.prank(validator1);
        staking.claimDelegatorFeeAtEpoch(validator1, epoch + 1);
    }

    function test_delegatorCanClaimNewRewardsWithoutNewDelegations() public {
        _deploy(
            5, 50, 150, 7, 0, ONE, ONE, _emptyAddresses(), _emptyUint256s(), _singleton(treasury), _singleton16(10_000)
        );
        staking.addValidator(validator1);
        vm.prank(staker1);
        staking.delegate{value: ONE}(validator1);
        _rollToNextEpoch();

        _depositReward(validator1, ONE);
        _rollToNextEpoch();
        assertEq(staking.getDelegatorFee(validator1, staker1), ONE);
        vm.prank(staker1);
        staking.claimDelegatorFee(validator1);

        _rollToNextEpoch();
        _depositReward(validator1, ONE);
        _rollToNextEpoch();
        assertEq(staking.getDelegatorFee(validator1, staker1), ONE);
    }

    function test_jailedValidatorLeavesAndRejoinsActiveSet() public {
        address[] memory validators = new address[](2);
        validators[0] = validator1;
        validators[1] = validator2;
        uint256[] memory stakes = new uint256[](2);
        _deploy(50, 5, 10, 1, 0, ONE, ONE, validators, stakes, _singleton(treasury), _singleton16(10_000));

        assertEq(staking.getValidators().length, 2);
        for (uint256 i = 0; i < 10; i++) {
            _slash(validator1);
        }
        address[] memory active = staking.getValidators();
        assertEq(active.length, 1);
        assertEq(active[0], validator2);

        _rollToNextEpoch();
        _rollToNextEpoch();
        vm.prank(validator1);
        staking.releaseValidatorFromJail(validator1);
        assertEq(staking.getValidators().length, 2);
    }

    function test_userCanRedelegateStakingRewards() public {
        _deploy(
            10,
            50,
            150,
            7,
            0,
            ONE,
            ONE,
            _singleton(validator1),
            _singletonUint(0),
            _singleton(treasury),
            _singleton16(10_000)
        );

        vm.prank(staker1);
        staking.delegate{value: ONE}(validator1);
        _rollToNextEpoch();
        _depositReward(validator1, ONE + 123);
        _rollToNextEpoch();

        assertEq(staking.getDelegatorFee(validator1, staker1), ONE + 123);
        (uint256 amountToStake, uint256 rewardsDust) = staking.calcAvailableForRedelegateAmount(validator1, staker1);
        assertEq(amountToStake, ONE);
        assertEq(rewardsDust, 123);

        vm.prank(staker1);
        staking.redelegateDelegatorFee(validator1);
        _rollToNextEpoch();
        assertEq(staking.getDelegatorFee(validator1, staker1), 0);
        (uint256 delegated,) = staking.getValidatorDelegation(validator1, staker1);
        assertEq(delegated, 2 * ONE);
    }

    function test_systemFeeCalculationAndDistribution() public {
        _sendSystemFee(49 ether);
        assertEq(address(systemReward).balance, 49 ether);
        assertEq(systemReward.getSystemFee(), 49 ether);

        systemReward.claimSystemFee();
        assertEq(treasury.balance, 1_049 ether);
        assertEq(systemReward.getSystemFee(), 0);

        address[] memory accounts = new address[](3);
        accounts[0] = treasury;
        accounts[1] = owner;
        accounts[2] = validator1;
        uint16[] memory shares = new uint16[](3);
        shares[0] = 5_000;
        shares[1] = 2_500;
        shares[2] = 2_500;
        systemReward.updateDistributionShare(accounts, shares);

        _sendSystemFee(49 ether);
        systemReward.claimSystemFee();
        assertEq(treasury.balance, 1_073.5 ether);
        assertEq(owner.balance, 1_012.25 ether);
        assertEq(validator1.balance, 1_012.25 ether);
    }

    function test_systemRewardDustAndShareValidation() public {
        address[] memory accounts = new address[](2);
        accounts[0] = treasury;
        accounts[1] = owner;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 1_000;
        shares[1] = 9_000;
        systemReward.updateDistributionShare(accounts, shares);

        _sendSystemFee(12_345);
        systemReward.claimSystemFee();
        assertEq(systemReward.getSystemFee(), 1);

        accounts = new address[](1);
        accounts[0] = treasury;
        shares = new uint16[](1);
        shares[0] = 9_999;
        vm.expectRevert(StakingErrors.BadShareDistribution.selector);
        systemReward.updateDistributionShare(accounts, shares);
    }

    function test_systemRewardDecreaseDistributionArraySize() public {
        address[] memory accounts = new address[](2);
        accounts[0] = treasury;
        accounts[1] = owner;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 1_000;
        shares[1] = 9_000;
        systemReward.updateDistributionShare(accounts, shares);
        assertEq(systemReward.getDistributionShares().length, 2);

        accounts = new address[](1);
        accounts[0] = treasury;
        shares = new uint16[](1);
        shares[0] = 10_000;
        systemReward.updateDistributionShare(accounts, shares);
        assertEq(systemReward.getDistributionShares().length, 1);
        assertEq(systemReward.getDistributionShares()[0].account, treasury);
    }

    function test_emptyDelegatorClaimAndPoolClaimDoNotRevert() public {
        staking.addValidator(validator1);
        vm.prank(staker1);
        staking.claimDelegatorFee(validator1);
    }

    function test_stakingPoolViewsAndPendingClaimableRewards() public {
        staking.addValidator(validator1);
        assertEq(stakingPool.getRatio(validator1), 1e18);

        vm.prank(staker1);
        stakingPool.stake{value: 10 * ONE}(validator1);
        _rollToNextEpoch();
        _depositReward(validator1, ONE);
        _rollToNextEpoch();

        vm.prank(staker2);
        stakingPool.stake{value: ONE}(validator1);

        assertGt(stakingPool.getShares(validator1, staker1), 0);
        StakingPool.ValidatorPool memory pool = stakingPool.getValidatorPool(validator1);
        assertEq(pool.validatorAddress, validator1);
        assertEq(pool.totalStakedAmount, 12 * ONE);

        vm.prank(staker1);
        stakingPool.unstake(validator1, ONE);
        assertEq(stakingPool.claimableRewards(validator1, staker1), ONE);

        assertEq(stakingPool.claimableRewards(validator1, staker2), 0);
    }

    function test_systemFeeAutoClaimAfterThreshold() public {
        uint256 initial = treasury.balance;
        _sendSystemFee(49 ether);
        assertEq(treasury.balance, initial);
        _sendSystemFee(2 ether);
        assertEq(treasury.balance, initial + 51 ether);
        assertEq(systemReward.getSystemFee(), 0);
    }

    function _deploy(
        uint32 epochBlockInterval,
        uint32 misdemeanorThreshold,
        uint32 felonyThreshold,
        uint32 validatorJailEpochLength,
        uint32 undelegatePeriod,
        uint256 minValidatorStakeAmount,
        uint256 minStakingAmount,
        address[] memory initialValidators,
        uint256[] memory initialStakes,
        address[] memory rewardAccounts,
        uint16[] memory rewardShares
    ) internal {
        uint64 nonce = vm.getNonce(address(this));
        IStaking predictedStaking = IStaking(vm.computeCreateAddress(address(this), nonce + 1));
        ISlashingIndicator predictedSlashingIndicator =
            ISlashingIndicator(vm.computeCreateAddress(address(this), nonce + 3));
        ISystemReward predictedSystemReward = ISystemReward(vm.computeCreateAddress(address(this), nonce + 5));
        IStakingPool predictedStakingPool = IStakingPool(vm.computeCreateAddress(address(this), nonce + 7));
        IChainConfig predictedChainConfig = IChainConfig(vm.computeCreateAddress(address(this), nonce + 9));
        IGovernance governance = IGovernance(address(this));

        Staking stakingImpl = new Staking(
            predictedStaking,
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig
        );
        staking = Staking(
            payable(address(
                    new ERC1967Proxy{value: _sum(initialStakes)}(
                        address(stakingImpl),
                        abi.encodeCall(Staking.initialize, (address(this), initialValidators, initialStakes, 0))
                    )
                ))
        );

        SlashingIndicator slashingIndicatorImpl = new SlashingIndicator(
            predictedStaking,
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig
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
            predictedChainConfig
        );
        systemReward = SystemReward(
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
            governance,
            predictedChainConfig
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
            predictedChainConfig
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
                            epochBlockInterval,
                            misdemeanorThreshold,
                            felonyThreshold,
                            validatorJailEpochLength,
                            undelegatePeriod,
                            minValidatorStakeAmount,
                            minStakingAmount
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
    }

    function _sum(uint256[] memory values) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < values.length; i++) {
            total += values[i];
        }
    }

    function _sendSystemFee(uint256 amount) internal {
        (bool success,) = address(systemReward).call{value: amount}("");
        require(success, "system fee transfer failed");
    }

    function _depositReward(address validator, uint256 amount) internal {
        vm.coinbase(validator);
        vm.prank(validator);
        staking.deposit{value: amount}(validator);
    }

    function _slash(address validator) internal {
        vm.coinbase(address(this));
        slashingIndicator.slash(validator);
    }

    function _rollToNextEpoch() internal {
        vm.roll(block.number + chainConfig.getEpochBlockInterval());
    }

    function _emptyAddresses() internal pure returns (address[] memory values) {
        values = new address[](0);
    }

    function _emptyUint256s() internal pure returns (uint256[] memory values) {
        values = new uint256[](0);
    }

    function _singleton(address value) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _singletonUint(uint256 value) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function _singleton16(uint16 value) internal pure returns (uint16[] memory values) {
        values = new uint16[](1);
        values[0] = value;
    }
}
