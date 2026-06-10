// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStaking, IStakingEvents, IStakingErrors} from "./interfaces/IStaking.sol";
import {ISystemReward} from "./interfaces/ISystemReward.sol";
import {IStakingPool} from "./interfaces/IStakingPool.sol";
import {IFluentGovernance} from "./interfaces/IFluentGovernance.sol";
import {IChainConfig} from "./interfaces/IChainConfig.sol";
import {StakingContext} from "./StakingContext.sol";
import {StakingLayout} from "./StakingLayout.sol";
import {StakingDpos} from "./StakingDpos.sol";

/**
 * @title Validator staking
 * @author Fluent Labs
 * @notice Manages validator registration, delegation, undelegation, commission, reward claims, active set ordering, and slashing.
 * @dev Uses epoch snapshots and compacted balances to preserve historical accounting without storing full uint256 stake values.
 */
contract Staking is IStaking, StakingContext {
    using SafeERC20 for IERC20;

    /// @notice Two-epoch warmup: stake delegated in epoch e becomes effective at
    ///         e+2 (PoS spec §4.2). This depth is what lets the committee for epoch
    ///         N be selected one epoch ahead. committee[N] is selected from
    ///         EffBal(N-1) = snapshot[N-1] (§4.4); with WARMUP_DELAY=2 its
    ///         contributing delegations come from epoch (N-1)-WARMUP_DELAY = N-3, so
    ///         snapshot[N-1] is final by the first block of epoch N-1 — see
    ///         commitEpochCommittee's `target <= currentEpoch+1` gate.
    uint64 internal constant WARMUP_DELAY = 2;

    /**
     * Here is min/max commission rates. Lets don't allow to set more than 30% of validator commission, because it's
     * too big commission for validator. Commission rate is a percents divided by 100 stored with 0 decimals as percents*100 (=pc/1e2*1e4)
     *
     * Here is some examples:
     * + 0.3% => 0.3*100=30
     * + 3% => 3*100=300
     * + 30% => 30*100=3000
     */
    uint16 internal constant COMMISSION_RATE_MIN_VALUE = 0; // 0%
    uint16 internal constant COMMISSION_RATE_MAX_VALUE = 3000; // 30%
    /**
     * @dev Maximum number of epochs processed by a single state-changing claim.
     *
     * This bounds reward and undelegation iteration so accounts with long unclaimed ranges can
     * settle progressively instead of requiring one transaction to process the entire history.
     */
    uint64 internal constant MAX_EPOCHS_PER_CLAIM = 1000;

    /// @notice V1: liveness slasher predeploy address. ACL'd as a private
    ///         immutable here rather than as a `StakingContext` field so the
    ///         constructor cascade is isolated to `Staking.sol`.
    address private immutable _livenessSlashingAddr;

    constructor(
        IStaking stakingContract,
        ISystemReward systemRewardContract,
        IStakingPool stakingPoolContract,
        IFluentGovernance governanceContract,
        IChainConfig chainConfigContract,
        IERC20 stakingToken,
        address livenessSlashingAddr
    )
        StakingContext(
            stakingContract,
            systemRewardContract,
            stakingPoolContract,
            governanceContract,
            chainConfigContract,
            stakingToken
        )
    {
        _livenessSlashingAddr = livenessSlashingAddr;
    }

    /// @dev Gates the
    ///      `LivenessSlashing` predeploy as the sole caller of
    ///      `slash`.
    modifier onlyFromLivenessSlashing() {
        require(msg.sender == _livenessSlashingAddr, OnlyLivenessSlashing());
        _;
    }

    /**
     * @param initialOwner The address of the initial owner of the staking contract.
     * @param validators The addresses of initial validators to be added to the staking contract.
     * @param initialStakes The initial stakes of the validators.
     * @param commissionRate The commission rate of the validators.
     */
    function initialize(
        address initialOwner,
        address[] calldata validators,
        uint256[] calldata initialStakes,
        uint16 commissionRate
    ) external initializer {
        __StakingContext_init(initialOwner);
        uint256 numValidators = validators.length;
        require(initialStakes.length == numValidators, MalformedInputLength());
        uint256 totalStakes = 0;
        for (uint256 i = 0; i < numValidators;) {
            _addValidator(validators[i], validators[i], ValidatorStatus.Active, commissionRate, initialStakes[i], 0);
            totalStakes += initialStakes[i];
            unchecked {
                ++i;
            }
        }

        /// transfer stToken to the contract
        if (totalStakes > 0) _stakingToken.safeTransferFrom(msg.sender, address(this), totalStakes);
    }

    // @inheritdoc IStaking
    function getValidatorDelegation(address validatorAddress, address delegator)
        external
        view
        override
        returns (uint256 delegatedAmount, uint64 atEpoch)
    {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        ValidatorDelegation memory delegation = $._validatorDelegations[validatorAddress][delegator];
        if (delegation.delegateQueue.length == 0) {
            return (delegatedAmount = 0, atEpoch = 0);
        }
        DelegationOpDelegate memory snapshot = delegation.delegateQueue[delegation.delegateQueue.length - 1];
        return (
            delegatedAmount = uint256(snapshot.amount) * StakingLayout.BALANCE_COMPACT_PRECISION,
            atEpoch = snapshot.epoch
        );
    }

    /// @inheritdoc IStaking
    function getValidatorStatus(address validatorAddress)
        external
        view
        override
        returns (
            address ownerAddress,
            uint8 status,
            uint256 totalDelegated,
            uint32 slashesCount,
            uint64 changedAt,
            uint64 jailedBefore,
            uint64 claimedAt,
            uint16 commissionRate,
            uint96 totalRewards
        )
    {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        Validator memory validator = $._validatorsMap[validatorAddress];
        ValidatorSnapshot memory snapshot = $._validatorSnapshots[validator.validatorAddress][validator.changedAt];
        return (
            ownerAddress = validator.ownerAddress,
            status = uint8(validator.status),
            totalDelegated = uint256(snapshot.totalDelegated) * StakingLayout.BALANCE_COMPACT_PRECISION,
            slashesCount = snapshot.slashesCount,
            changedAt = validator.changedAt,
            jailedBefore = validator.jailedBefore,
            claimedAt = validator.claimedAt,
            commissionRate = snapshot.commissionRate,
            totalRewards = snapshot.totalRewards
        );
    }

    /// @inheritdoc IStaking
    function getValidatorStatusAtEpoch(address validatorAddress, uint64 epoch)
        external
        view
        returns (
            address ownerAddress,
            uint8 status,
            uint256 totalDelegated,
            uint32 slashesCount,
            uint64 changedAt,
            uint64 jailedBefore,
            uint64 claimedAt,
            uint16 commissionRate,
            uint96 totalRewards
        )
    {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        Validator memory validator = $._validatorsMap[validatorAddress];
        ValidatorSnapshot memory snapshot = _touchValidatorSnapshotImmutable(validator, epoch);
        return (
            ownerAddress = validator.ownerAddress,
            status = uint8(validator.status),
            totalDelegated = uint256(snapshot.totalDelegated) * StakingLayout.BALANCE_COMPACT_PRECISION,
            slashesCount = snapshot.slashesCount,
            changedAt = validator.changedAt,
            jailedBefore = validator.jailedBefore,
            claimedAt = validator.claimedAt,
            commissionRate = snapshot.commissionRate,
            totalRewards = snapshot.totalRewards
        );
    }

    /// @inheritdoc IStaking
    function getValidatorByOwner(address owner) external view override returns (address) {
        return StakingLayout.stakingStorage()._validatorOwners[owner];
    }

    /// @inheritdoc IStaking
    function releaseValidatorFromJail(address validatorAddress) external {
        if (StakingLayout.equivocationStorage().tombstoned[validatorAddress]) {
            revert AlreadySlashedForEquivocation(validatorAddress);
        }
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        // make sure validator is in jail
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status == ValidatorStatus.Jail, ValidatorNotInJail(validatorAddress));
        // only validator owner
        require(msg.sender == validator.ownerAddress, OnlyValidatorOwner(validator.ownerAddress));
        require(_currentEpoch() >= validator.jailedBefore, StillInJail(validatorAddress));
        // update validator status
        validator.status = ValidatorStatus.Active;
        $._validatorsMap[validatorAddress] = validator;
        $._activeValidatorsList.push(validatorAddress);
        // emit event
        emit ValidatorReleased(validatorAddress, _currentEpoch());
    }

    function _totalDelegatedToValidator(Validator memory validator) internal view returns (uint256) {
        return StakingLayout.totalDelegatedToValidatorAt(validator, _currentEpoch());
    }

    function delegate(address validatorAddress, uint256 amount) external override {
        _delegateTo(msg.sender, validatorAddress, amount, true);
    }

    function undelegate(address validatorAddress, uint256 amount) external override {
        _undelegateFrom(msg.sender, validatorAddress, amount);
    }

    function currentEpoch() external view returns (uint64) {
        return _currentEpoch();
    }

    function nextEpoch() external view returns (uint64) {
        return _nextEpoch();
    }

    function _currentEpoch() internal view returns (uint64) {
        // DPoS epochs are numbered relative to `dposActivationBlock` so a
        // Tempo→DPoS migration anchor at a high block becomes epoch 0 (see
        // ChainConfig.dposActivationBlock). Pre-activation blocks clamp to 0 —
        // reachable only in a predeploy window before the switch; in production
        // the contract is introduced at activation so block.number >= activation
        // always holds. activation == 0 ⇒ absolute numbering (degenerate).
        uint64 activation = _chainConfigContract.getDposActivationBlock();
        if (block.number < activation) {
            return 0;
        }
        return uint64((block.number - activation) / _chainConfigContract.getEpochBlockInterval());
    }

    function _nextEpoch() internal view returns (uint64) {
        return _currentEpoch() + 1;
    }

    function _touchValidatorSnapshot(Validator memory validator, uint64 epoch)
        internal
        returns (ValidatorSnapshot storage)
    {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        ValidatorSnapshot storage snapshot = $._validatorSnapshots[validator.validatorAddress][epoch];
        // if snapshot is already initialized then just return it
        if (snapshot.totalDelegated > 0) {
            return snapshot;
        }
        // find previous snapshot to copy parameters from it
        ValidatorSnapshot memory lastModifiedSnapshot =
            $._validatorSnapshots[validator.validatorAddress][validator.changedAt];
        // last modified snapshot might store zero value, for first delegation it might happen and its not critical
        snapshot.totalDelegated = lastModifiedSnapshot.totalDelegated;
        snapshot.commissionRate = lastModifiedSnapshot.commissionRate;
        // we must save last affected epoch for this validator to be able to restore total delegated
        // amount in the future (check condition upper)
        if (epoch > validator.changedAt) {
            validator.changedAt = epoch;
        }
        return snapshot;
    }

    function _touchValidatorSnapshotImmutable(Validator memory validator, uint64 epoch)
        internal
        view
        returns (ValidatorSnapshot memory)
    {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        ValidatorSnapshot memory snapshot = $._validatorSnapshots[validator.validatorAddress][epoch];
        // if snapshot is already initialized then just return it
        if (snapshot.totalDelegated > 0) {
            return snapshot;
        }
        // find previous snapshot to copy parameters from it
        ValidatorSnapshot memory lastModifiedSnapshot =
            $._validatorSnapshots[validator.validatorAddress][validator.changedAt];
        // last modified snapshot might store zero value, for first delegation it might happen and its not critical
        snapshot.totalDelegated = lastModifiedSnapshot.totalDelegated;
        snapshot.commissionRate = lastModifiedSnapshot.commissionRate;
        // return existing or new snapshot
        return snapshot;
    }

    function _delegateTo(address fromDelegator, address toValidator, uint256 amount, bool pullTokens) internal {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        // check is minimum delegate amount
        require(amount >= _chainConfigContract.getMinStakingAmount() && amount > 0, AmountTooLow(amount));
        require(amount % StakingLayout.BALANCE_COMPACT_PRECISION == 0, WrongAmountPrecision());
        // make sure validator exists at least
        Validator memory validator = $._validatorsMap[toValidator];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(toValidator));
        uint64 atEpoch = _currentEpoch() + WARMUP_DELAY; // warmup: effective at epoch e+2
        // Upgrade the warmup-target (e+2) snapshot:
        // + find snapshot for atEpoch (e+2)
        // + increase total delegated amount at atEpoch for this validator
        // + re-save validator because last affected epoch might change
        ValidatorSnapshot storage validatorSnapshot = _touchValidatorSnapshot(validator, atEpoch);
        validatorSnapshot.totalDelegated += uint112(amount / StakingLayout.BALANCE_COMPACT_PRECISION);
        $._validatorsMap[toValidator] = validator;
        // if last pending delegate has the same next epoch then its safe to just increase total
        // staked amount because it can't affect current validator set, but otherwise we must create
        // new record in delegation queue with the last epoch (delegations are ordered by epoch)
        ValidatorDelegation storage delegation = $._validatorDelegations[toValidator][fromDelegator];
        if (delegation.delegateQueue.length > 0) {
            DelegationOpDelegate storage recentDelegateOp =
                delegation.delegateQueue[delegation.delegateQueue.length - 1];
            // if we already have pending snapshot for the next epoch then just increase new amount,
            // otherwise create next pending snapshot. (tbh it can't be greater, but what we can do here instead?)
            if (recentDelegateOp.epoch >= atEpoch) {
                recentDelegateOp.amount += uint112(amount / StakingLayout.BALANCE_COMPACT_PRECISION);
            } else {
                delegation.delegateQueue
                    .push(
                        DelegationOpDelegate({
                            epoch: atEpoch,
                            amount: recentDelegateOp.amount + uint112(amount / StakingLayout.BALANCE_COMPACT_PRECISION)
                        })
                    );
            }
        } else {
            // there is no any delegations at al, lets create the first one
            delegation.delegateQueue
                .push(
                    DelegationOpDelegate({
                        epoch: atEpoch, amount: uint112(amount / StakingLayout.BALANCE_COMPACT_PRECISION)
                    })
                );
        }
        // CEI: pull tokens after all state updates. If the staking token ever becomes
        // callback-style (ERC-777), a reentrant re-entry would observe consistent state.
        if (pullTokens) {
            _stakingToken.safeTransferFrom(fromDelegator, address(this), amount);
        }
        // emit event with the next epoch
        emit Delegated(toValidator, fromDelegator, amount, atEpoch);
    }

    function _undelegateFrom(address toDelegator, address fromValidator, uint256 amount) internal {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        // check minimum delegate amount
        require(amount >= _chainConfigContract.getMinStakingAmount() && amount > 0, AmountTooLow(amount));
        require(amount % StakingLayout.BALANCE_COMPACT_PRECISION == 0, WrongAmountPrecision());
        // make sure validator exists at least
        Validator memory validator = $._validatorsMap[fromValidator];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(fromValidator));
        uint64 beforeEpoch = _nextEpoch();
        // Lets upgrade next snapshot parameters:
        // + find snapshot for the next epoch after current block
        // + increase total delegated amount in the next epoch for this validator
        // + re-save validator because last affected epoch might change
        ValidatorSnapshot storage validatorSnapshot = _touchValidatorSnapshot(validator, beforeEpoch);
        require(
            validatorSnapshot.totalDelegated >= uint112(amount / StakingLayout.BALANCE_COMPACT_PRECISION),
            InsufficientBalance()
        );
        validatorSnapshot.totalDelegated -= uint112(amount / StakingLayout.BALANCE_COMPACT_PRECISION);
        $._validatorsMap[fromValidator] = validator;
        // if last pending delegate has the same next epoch then its safe to just increase total
        // staked amount because it can't affect current validator set, but otherwise we must create
        // new record in delegation queue with the last epoch (delegations are ordered by epoch)
        ValidatorDelegation storage delegation = $._validatorDelegations[fromValidator][toDelegator];
        require(delegation.delegateQueue.length > 0, DelegationQueueEmpty());
        DelegationOpDelegate storage recentDelegateOp = delegation.delegateQueue[delegation.delegateQueue.length - 1];
        require(
            recentDelegateOp.amount >= uint112(amount / StakingLayout.BALANCE_COMPACT_PRECISION), InsufficientBalance()
        );
        uint112 nextDelegatedAmount =
            recentDelegateOp.amount - uint112(amount / StakingLayout.BALANCE_COMPACT_PRECISION);
        // Keep the owner self-stake above the validator minimum while other delegators remain.
        // If the owner is the sole remaining delegator, a full exit is allowed so governance can
        // remove the validator after the undelegation takes effect.
        if (
            toDelegator == validator.ownerAddress
                && (validator.status == ValidatorStatus.Active || validator.status == ValidatorStatus.Pending)
        ) {
            uint256 selfStakeRemaining = uint256(nextDelegatedAmount) * StakingLayout.BALANCE_COMPACT_PRECISION;
            uint256 totalStakeRemaining =
                uint256(validatorSnapshot.totalDelegated) * StakingLayout.BALANCE_COMPACT_PRECISION;
            if (
                selfStakeRemaining < _chainConfigContract.getMinValidatorStakeAmount()
                    && totalStakeRemaining != selfStakeRemaining
            ) {
                revert OwnerSelfStakeBelowMinimum();
            }
        }
        if (recentDelegateOp.epoch >= beforeEpoch) {
            // decrease total delegated amount for the next epoch
            recentDelegateOp.amount = nextDelegatedAmount;
        } else {
            // there is no pending delegations, so lets create the new one with the new amount
            delegation.delegateQueue.push(DelegationOpDelegate({epoch: beforeEpoch, amount: nextDelegatedAmount}));
        }
        // create new undelegate queue operation with soft lock
        delegation.undelegateQueue
            .push(
                DelegationOpUndelegate({
                    amount: uint112(amount / StakingLayout.BALANCE_COMPACT_PRECISION),
                    epoch: beforeEpoch + _chainConfigContract.getUndelegatePeriod()
                })
            );
        // emit event with the next epoch number
        emit Undelegated(fromValidator, toDelegator, amount, beforeEpoch);
    }

    /**
     * @dev Returns `beforeEpoch` capped to the first unprocessed epoch plus `MAX_EPOCHS_PER_CLAIM`.
     *
     * The first unprocessed epoch is taken from the delegation queue head. If the delegation queue
     * is fully processed, the undelegation queue head is used instead.
     */
    function _cappedDelegatorClaimEpoch(ValidatorDelegation storage delegation, uint64 beforeEpoch)
        internal
        view
        returns (uint64)
    {
        uint64 firstUnprocessed;
        if (delegation.delegateGap < delegation.delegateQueue.length) {
            firstUnprocessed = delegation.delegateQueue[delegation.delegateGap].epoch;
        } else if (delegation.undelegateGap < delegation.undelegateQueue.length) {
            firstUnprocessed = delegation.undelegateQueue[delegation.undelegateGap].epoch;
        } else {
            return beforeEpoch;
        }
        uint64 cappedTo = firstUnprocessed + MAX_EPOCHS_PER_CLAIM;
        return cappedTo < beforeEpoch ? cappedTo : beforeEpoch;
    }

    function _claimDelegatorRewardsAndPendingUndelegates(
        address validator,
        address delegator,
        uint64 beforeEpochExclude,
        ClaimMode claimMode
    ) internal {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        ValidatorDelegation storage delegation = $._validatorDelegations[validator][delegator];
        // Bound the number of processed epochs; callers can repeat claims to drain longer ranges.
        beforeEpochExclude = _cappedDelegatorClaimEpoch(delegation, beforeEpochExclude);
        uint256 availableFunds = 0;
        // process delegate queue to calculate staking rewards
        uint64 delegateGap = delegation.delegateGap;
        for (uint256 queueLength = delegation.delegateQueue.length; delegateGap < queueLength;) {
            DelegationOpDelegate memory delegateOp = delegation.delegateQueue[delegateGap];
            if (delegateOp.epoch >= beforeEpochExclude) {
                break;
            }
            uint256 voteChangedAtEpoch = 0;
            if (delegateGap < queueLength - 1) {
                voteChangedAtEpoch = delegation.delegateQueue[delegateGap + 1].epoch;
            }
            for (
                ;
                delegateOp.epoch < beforeEpochExclude
                    && (voteChangedAtEpoch == 0 || delegateOp.epoch < voteChangedAtEpoch);
                delegateOp.epoch++
            ) {
                ValidatorSnapshot memory validatorSnapshot = $._validatorSnapshots[validator][delegateOp.epoch];
                if (validatorSnapshot.totalDelegated == 0) {
                    continue;
                }
                (
                    uint256 delegatorFee,, /*uint256 ownerFee*/ /*uint256 systemFee*/
                ) = _calcValidatorSnapshotEpochPayout(validatorSnapshot);
                availableFunds += (delegatorFee * delegateOp.amount) / validatorSnapshot.totalDelegated;
            }
            // if we have reached end of the delegation list then lets stay on the last item, but with updated latest processed epoch
            if (delegateGap >= queueLength - 1) {
                delegation.delegateQueue[delegateGap] = delegateOp;
                break;
            }
            delete delegation.delegateQueue[delegateGap];
            ++delegateGap;
        }
        delegation.delegateGap = delegateGap;
        // process all items from undelegate queue
        uint64 undelegateGap = delegation.undelegateGap;
        for (uint256 queueLength = delegation.undelegateQueue.length; undelegateGap < queueLength;) {
            DelegationOpUndelegate memory undelegateOp = delegation.undelegateQueue[undelegateGap];
            if (undelegateOp.epoch > beforeEpochExclude) {
                break;
            }
            availableFunds += uint256(undelegateOp.amount) * StakingLayout.BALANCE_COMPACT_PRECISION;
            delete delegation.undelegateQueue[undelegateGap];
            ++undelegateGap;
        }
        delegation.undelegateGap = undelegateGap;
        // send available for claim funds to delegator
        if (claimMode == ClaimMode.Transfer) {
            // for transfer claim mode just all rewards to the user
            _safeTransfer(delegator, availableFunds);
            // emit event
            emit Claimed(validator, delegator, availableFunds, beforeEpochExclude);
        } else if (claimMode == ClaimMode.Redelegate) {
            (uint256 amountToStake, uint256 rewardsDust) = _calcAvailableForRedelegateAmount(availableFunds);
            // if we have something to re-stake then delegate it to the validator
            if (amountToStake > 0) {
                _delegateTo(delegator, validator, amountToStake, false);
            }
            // if we have dust from staking then send it to user
            if (rewardsDust > 0) {
                _safeTransfer(delegator, rewardsDust);
            }
            // emit event
            emit Redelegated(validator, delegator, amountToStake, rewardsDust, beforeEpochExclude);
        } else {
            // this case is not possible, no error for less bytecode
            revert NotEnoughBalance();
        }
    }

    function _calcDelegatorRewardsAndPendingUndelegates(address validator, address delegator, uint64 beforeEpoch)
        internal
        view
        returns (uint256)
    {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        ValidatorDelegation memory delegation = $._validatorDelegations[validator][delegator];
        uint256 availableFunds = 0;
        // process delegate queue to calculate staking rewards
        while (delegation.delegateGap < delegation.delegateQueue.length) {
            DelegationOpDelegate memory delegateOp = delegation.delegateQueue[delegation.delegateGap];
            if (delegateOp.epoch >= beforeEpoch) {
                break;
            }
            uint256 voteChangedAtEpoch = 0;
            if (delegation.delegateGap < delegation.delegateQueue.length - 1) {
                voteChangedAtEpoch = delegation.delegateQueue[delegation.delegateGap + 1].epoch;
            }
            for (
                ;
                delegateOp.epoch < beforeEpoch && (voteChangedAtEpoch == 0 || delegateOp.epoch < voteChangedAtEpoch);
                delegateOp.epoch++
            ) {
                ValidatorSnapshot memory validatorSnapshot = $._validatorSnapshots[validator][delegateOp.epoch];
                if (validatorSnapshot.totalDelegated == 0) {
                    continue;
                }
                (
                    uint256 delegatorFee,, /*uint256 ownerFee*/ /*uint256 systemFee*/
                ) = _calcValidatorSnapshotEpochPayout(validatorSnapshot);
                availableFunds += (delegatorFee * delegateOp.amount) / validatorSnapshot.totalDelegated;
            }
            ++delegation.delegateGap;
        }
        // process all items from undelegate queue
        while (delegation.undelegateGap < delegation.undelegateQueue.length) {
            DelegationOpUndelegate memory undelegateOp = delegation.undelegateQueue[delegation.undelegateGap];
            if (undelegateOp.epoch > beforeEpoch) {
                break;
            }
            availableFunds += uint256(undelegateOp.amount) * StakingLayout.BALANCE_COMPACT_PRECISION;
            ++delegation.undelegateGap;
        }
        // return available for claim funds
        return availableFunds;
    }

    function _claimValidatorOwnerRewards(Validator storage validator, uint64 beforeEpoch) internal {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        // Bound the number of processed epochs; owners can repeat claims to drain longer ranges.
        uint64 cappedTo = validator.claimedAt + MAX_EPOCHS_PER_CLAIM;
        if (cappedTo < beforeEpoch) {
            beforeEpoch = cappedTo;
        }
        uint256 availableFunds = 0;
        uint256 systemFee = 0;
        uint64 claimAt = validator.claimedAt;
        for (; claimAt < beforeEpoch; claimAt++) {
            ValidatorSnapshot memory validatorSnapshot = $._validatorSnapshots[validator.validatorAddress][claimAt];
            (/*uint256 delegatorFee*/, uint256 ownerFee, uint256 slashingFee) =
                _calcValidatorSnapshotEpochPayout(validatorSnapshot);
            availableFunds += ownerFee;
            systemFee += slashingFee;
        }
        validator.claimedAt = claimAt;
        _safeTransfer(validator.ownerAddress, availableFunds);
        // if we have system fee then pay it to treasury account
        if (systemFee > 0) {
            _stakingToken.forceApprove(address(_systemRewardContract), systemFee);
            _systemRewardContract.deposit(systemFee);
        }
        emit ValidatorOwnerClaimed(validator.validatorAddress, availableFunds, beforeEpoch);
    }

    function _calcValidatorOwnerRewards(Validator memory validator, uint64 beforeEpoch)
        internal
        view
        returns (uint256)
    {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        uint256 availableFunds = 0;
        for (; validator.claimedAt < beforeEpoch; validator.claimedAt++) {
            ValidatorSnapshot memory validatorSnapshot =
                $._validatorSnapshots[validator.validatorAddress][validator.claimedAt];
            (
                /*uint256 delegatorFee*/,
                uint256 ownerFee, /*uint256 systemFee*/
            ) = _calcValidatorSnapshotEpochPayout(validatorSnapshot);
            availableFunds += ownerFee;
        }
        return availableFunds;
    }

    function _calcValidatorSnapshotEpochPayout(ValidatorSnapshot memory validatorSnapshot)
        internal
        view
        returns (uint256 delegatorFee, uint256 ownerFee, uint256 systemFee)
    {
        // Reward cliff at misdemeanor (NOT felony): once `slashesCount`
        // crosses `misdemeanorThreshold` (default 50), BOTH delegator and
        // owner rewards are zeroed and everything routes to the system
        // treasury — even though felony/jailing only kicks in at
        // `felonyThreshold` (default 150). This is an intentional asymmetry:
        // punishment ramps up well before jailing.
        if (validatorSnapshot.slashesCount >= _chainConfigContract.getMisdemeanorThreshold()) {
            return (delegatorFee = 0, ownerFee = 0, systemFee = validatorSnapshot.totalRewards);
        } else if (validatorSnapshot.totalDelegated == 0) {
            return (delegatorFee = 0, ownerFee = validatorSnapshot.totalRewards, systemFee = 0);
        }
        // ownerFee_(18+4-4=18) = totalRewards_18 * commissionRate_4 / 1e4
        ownerFee = (uint256(validatorSnapshot.totalRewards) * validatorSnapshot.commissionRate) / 1e4;
        // delegatorRewards = totalRewards - ownerFee
        delegatorFee = validatorSnapshot.totalRewards - ownerFee;
        // default system fee is zero for epoch
        systemFee = 0;
    }

    /// @inheritdoc IStaking
    function registerValidator(address validatorAddress, uint16 commissionRate, uint256 initialStake)
        external
        override
    {
        // initial stake amount should be greater than minimum validator staking amount
        require(initialStake >= _chainConfigContract.getMinValidatorStakeAmount(), InitialStakeTooLow(initialStake));
        require(initialStake % StakingLayout.BALANCE_COMPACT_PRECISION == 0, WrongAmountPrecision());
        // Add the validator before pulling tokens so all validation and accounting complete first.
        _addValidator(validatorAddress, msg.sender, ValidatorStatus.Pending, commissionRate, initialStake, _nextEpoch());
        _stakingToken.safeTransferFrom(msg.sender, address(this), initialStake);
    }

    /// @inheritdoc IStaking
    function addValidator(address account) external virtual override onlyFromGovernance {
        _addValidator(account, account, ValidatorStatus.Active, 0, 0, _nextEpoch());
    }

    function _addValidator(
        address validatorAddress,
        address validatorOwner,
        ValidatorStatus status,
        uint16 commissionRate,
        uint256 initialStake,
        uint64 sinceEpoch
    ) internal {
        require(validatorAddress != address(0), ZeroValidator());
        require(validatorOwner != address(0), ZeroOwner());
        require(initialStake % StakingLayout.BALANCE_COMPACT_PRECISION == 0, WrongAmountPrecision());
        // Runtime additions must not target a future epoch. Genesis initialization uses epoch 0
        // before the chain config contract exists at its predicted address.
        if (sinceEpoch > 0) {
            require(sinceEpoch <= _nextEpoch(), InvalidEpoch());
        }

        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        // validator commission rate
        require(
            commissionRate >= COMMISSION_RATE_MIN_VALUE && commissionRate <= COMMISSION_RATE_MAX_VALUE,
            BadCommissionRate(commissionRate)
        );

        // init validator default params
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status == ValidatorStatus.NotFound, ValidatorAlreadyExists(validatorAddress));
        validator.validatorAddress = validatorAddress;
        validator.ownerAddress = validatorOwner;
        validator.status = status;
        validator.changedAt = sinceEpoch;
        $._validatorsMap[validatorAddress] = validator;
        // save validator owner
        require($._validatorOwners[validatorOwner] == address(0x00), ValidatorOwnerAlreadyInUse(validatorAddress));
        $._validatorOwners[validatorOwner] = validatorAddress;
        // add new validator to array
        if (status == ValidatorStatus.Active) {
            $._activeValidatorsList.push(validatorAddress);
        }
        // push initial validator snapshot at zero epoch with default params
        $._validatorSnapshots[validatorAddress][sinceEpoch] =
            ValidatorSnapshot(0, uint112(initialStake / StakingLayout.BALANCE_COMPACT_PRECISION), 0, commissionRate);
        // delegate initial stake to validator owner
        ValidatorDelegation storage delegation = $._validatorDelegations[validatorAddress][validatorOwner];
        require(delegation.delegateQueue.length == 0, DelegationQueueNotEmpty(delegation.delegateQueue.length));
        delegation.delegateQueue
            .push(DelegationOpDelegate(uint112(initialStake / StakingLayout.BALANCE_COMPACT_PRECISION), sinceEpoch));

        emit ValidatorAdded(validatorAddress, validatorOwner, uint8(status), commissionRate);
    }

    /// @inheritdoc IStaking
    function removeValidator(address account) external virtual override onlyFromGovernance {
        _removeValidator(account);
    }

    function _removeValidatorFromActiveList(address validatorAddress) internal {
        StakingLayout.removeFromActiveList(StakingLayout.stakingStorage(), validatorAddress);
    }

    function _removeValidator(address validatorAddress) internal {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress));
        // check if validator has active delegations
        require(_totalDelegatedToValidator(validator) == 0, ValidatorHasActiveDelegations(validatorAddress));
        // remove validator from active list if exists
        _removeValidatorFromActiveList(validatorAddress);
        // remove from validators map
        delete $._validatorOwners[validator.ownerAddress];
        delete $._validatorsMap[validatorAddress];
        emit ValidatorRemoved(validatorAddress);
    }

    /// @inheritdoc IStaking
    function activateValidator(address validator) external virtual override onlyFromGovernance {
        _activateValidator(validator);
    }

    function _activateValidator(address validatorAddress) internal {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status == ValidatorStatus.Pending, NotPendingValidator(validatorAddress));
        $._activeValidatorsList.push(validatorAddress);
        validator.status = ValidatorStatus.Active;
        // Persist after touching the snapshot because the call may advance `validator.changedAt`.
        ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(validator, _nextEpoch());
        $._validatorsMap[validatorAddress] = validator;

        emit ValidatorModified(
            validatorAddress, validator.ownerAddress, uint8(validator.status), snapshot.commissionRate
        );
    }

    /// @inheritdoc IStaking
    function disableValidator(address validator) external virtual override onlyFromGovernance {
        _disableValidator(validator);
    }

    function _disableValidator(address validatorAddress) internal {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status == ValidatorStatus.Active, NotActiveValidator());
        _removeValidatorFromActiveList(validatorAddress);
        validator.status = ValidatorStatus.Pending;
        // Persist after touching the snapshot because the call may advance `validator.changedAt`.
        ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(validator, _nextEpoch());
        $._validatorsMap[validatorAddress] = validator;

        emit ValidatorModified(
            validatorAddress, validator.ownerAddress, uint8(validator.status), snapshot.commissionRate
        );
    }

    /// @inheritdoc IStaking
    function changeValidatorCommissionRate(address validatorAddress, uint16 commissionRate) external {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        require(
            commissionRate >= COMMISSION_RATE_MIN_VALUE && commissionRate <= COMMISSION_RATE_MAX_VALUE,
            BadCommissionRate(commissionRate)
        );
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress));
        require(validator.ownerAddress == msg.sender, OnlyValidatorOwner(validator.ownerAddress));
        ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(validator, _nextEpoch());
        snapshot.commissionRate = commissionRate;
        $._validatorsMap[validatorAddress] = validator;

        emit ValidatorModified(
            validator.validatorAddress, validator.ownerAddress, uint8(validator.status), commissionRate
        );
    }

    /// @inheritdoc IStaking
    function changeValidatorOwner(address validatorAddress, address newOwner) external override {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        Validator memory validator = $._validatorsMap[validatorAddress];
        // Reject unknown validators before checking ownership so callers receive the correct error.
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress));
        require(validator.ownerAddress == msg.sender, OnlyValidatorOwner(validator.ownerAddress));
        require(newOwner != address(0), OwnerCantBeZero());
        require($._validatorOwners[newOwner] == address(0x00), ValidatorOwnerAlreadyInUse(validatorAddress));
        delete $._validatorOwners[validator.ownerAddress];
        validator.ownerAddress = newOwner;
        $._validatorOwners[newOwner] = validatorAddress;
        // Persist after touching the snapshot because the call may advance `validator.changedAt`.
        ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(validator, _nextEpoch());
        $._validatorsMap[validatorAddress] = validator;

        emit ValidatorModified(
            validator.validatorAddress, validator.ownerAddress, uint8(validator.status), snapshot.commissionRate
        );
    }

    /// @inheritdoc IStaking
    function isValidatorActive(address account) external view override returns (bool) {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        if ($._validatorsMap[account].status != ValidatorStatus.Active) {
            return false;
        }
        address[] memory topValidators = _getValidators();
        for (uint256 i = 0; i < topValidators.length; i++) {
            if (topValidators[i] == account) return true;
        }
        return false;
    }

    /// @inheritdoc IStaking
    function isValidator(address account) external view override returns (bool) {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        return $._validatorsMap[account].status != ValidatorStatus.NotFound;
    }

    function _getValidators() internal view returns (address[] memory) {
        return StakingLayout.getValidatorsAt(_chainConfigContract, _currentEpoch());
    }

    function getValidators() external view override returns (address[] memory) {
        return _getValidators();
    }

    function deposit(address validatorAddress, uint256 amount)
        external
        virtual
        override
        onlyFromCoinbase
        onlyZeroGasPrice
    {
        _depositFee(validatorAddress, amount);
    }

    function _depositFee(address validatorAddress, uint256 amount) internal {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        require(amount > 0, DepositIsZero());
        // make sure validator is active
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress));
        uint64 epoch = _currentEpoch();
        // increase total pending rewards for validator for current epoch
        ValidatorSnapshot storage currentSnapshot = _touchValidatorSnapshot(validator, epoch);
        currentSnapshot.totalRewards += uint96(amount);
        // Pull tokens after reward accounting is updated.
        _stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit ValidatorDeposited(validatorAddress, amount, epoch);
    }

    function getValidatorFee(address validatorAddress) external view override returns (uint256) {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        // make sure validator exists at least
        Validator memory validator = $._validatorsMap[validatorAddress];
        if (validator.status == ValidatorStatus.NotFound) {
            return 0;
        }
        // calc validator rewards
        return _calcValidatorOwnerRewards(validator, _currentEpoch());
    }

    function getPendingValidatorFee(address validatorAddress) external view override returns (uint256) {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        // make sure validator exists at least
        Validator memory validator = $._validatorsMap[validatorAddress];
        if (validator.status == ValidatorStatus.NotFound) {
            return 0;
        }
        // calc validator rewards
        return _calcValidatorOwnerRewards(validator, _nextEpoch());
    }

    function claimValidatorFee(address validatorAddress) external override {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        // make sure validator exists at least
        Validator storage validator = $._validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress));
        // settle all validator fees to the owner and slashed fees to the system reward contract
        _claimValidatorOwnerRewards(validator, _currentEpoch());
    }

    function claimValidatorFeeAtEpoch(address validatorAddress, uint64 beforeEpoch) external override {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        // make sure validator exists at least
        Validator storage validator = $._validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress));
        // we disallow to claim rewards from future epochs
        require(beforeEpoch <= _currentEpoch(), InvalidClaimEpoch());
        // settle validator fees to the owner and slashed fees to the system reward contract
        _claimValidatorOwnerRewards(validator, beforeEpoch);
    }

    function getDelegatorFee(address validatorAddress, address delegatorAddress)
        external
        view
        override
        returns (uint256)
    {
        return _calcDelegatorRewardsAndPendingUndelegates(validatorAddress, delegatorAddress, _currentEpoch());
    }

    function getPendingDelegatorFee(address validatorAddress, address delegatorAddress)
        external
        view
        override
        returns (uint256)
    {
        return _calcDelegatorRewardsAndPendingUndelegates(validatorAddress, delegatorAddress, _nextEpoch());
    }

    function claimDelegatorFee(address validatorAddress) external override {
        // claim all confirmed delegator fees including undelegates
        _claimDelegatorRewardsAndPendingUndelegates(validatorAddress, msg.sender, _currentEpoch(), ClaimMode.Transfer);
    }

    function _calcAvailableForRedelegateAmount(uint256 claimableRewards)
        internal
        view
        returns (uint256 amountToStake, uint256 rewardsDust)
    {
        // for redelegate we must split amount into stake-able and dust
        amountToStake =
            (claimableRewards / StakingLayout.BALANCE_COMPACT_PRECISION) * StakingLayout.BALANCE_COMPACT_PRECISION;
        if (amountToStake < _chainConfigContract.getMinStakingAmount()) {
            return (0, claimableRewards);
        }
        // if we have dust remaining after re-stake then send it to user (we can't keep it in the contract)
        return (amountToStake, claimableRewards - amountToStake);
    }

    function calcAvailableForRedelegateAmount(address validator, address delegator)
        external
        view
        override
        returns (uint256 amountToStake, uint256 rewardsDust)
    {
        uint256 claimableRewards = _calcDelegatorRewardsAndPendingUndelegates(validator, delegator, _currentEpoch());
        return _calcAvailableForRedelegateAmount(claimableRewards);
    }

    function redelegateDelegatorFee(address validator) external override {
        // claim rewards in the redelegate mode (check function code for more info)
        _claimDelegatorRewardsAndPendingUndelegates(validator, msg.sender, _currentEpoch(), ClaimMode.Redelegate);
    }

    function claimDelegatorFeeAtEpoch(address validatorAddress, uint64 beforeEpoch) external override {
        // make sure delegator can't claim future epochs
        require(beforeEpoch <= _currentEpoch(), InvalidClaimEpoch());
        // claim all confirmed delegator fees including undelegates
        _claimDelegatorRewardsAndPendingUndelegates(validatorAddress, msg.sender, beforeEpoch, ClaimMode.Transfer);
    }

    function _safeTransfer(address recipient, uint256 amount) internal {
        if (amount > 0) {
            _stakingToken.safeTransfer(recipient, amount);
        }
    }

    /// @notice Slash a validator for sustained liveness misses. Sole caller
    ///         is the `LivenessSlashing` predeploy. Reuses `_slashValidator`.
    function slash(address validatorAddress) external virtual override onlyFromLivenessSlashing {
        _slashValidator(validatorAddress);
    }

    /// @notice Register consensus keys for `validator` with on-chain
    ///         Proof-of-Possession. One-shot — no rotation in v1.
    /// @param blsPubkeyUncompressed 256 B EIP-2537 G2 — compressed on-chain
    ///                              to the stored 96 B identity.
    /// @param blsPoPUncompressed    128 B EIP-2537 G1 PoP signature — verify-only.
    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function setConsensusKeys(
        address validatorAddress,
        bytes calldata blsPubkeyUncompressed,
        bytes calldata blsPoPUncompressed,
        bytes32 peerPubkey
    ) external override {
        StakingDpos.setConsensusKeys(
            _chainConfigContract, validatorAddress, blsPubkeyUncompressed, blsPoPUncompressed, peerPubkey
        );
    }

    function getConsensusKeys(address validatorAddress) external view override returns (IStaking.ConsensusKeys memory) {
        return StakingLayout.consensusKeysStorage().consensusKeys[validatorAddress];
    }

    function getValidatorsWithKeys()
        external
        view
        override
        returns (address[] memory addrs, IStaking.ConsensusKeys[] memory keys)
    {
        addrs = _getValidators();
        keys = new IStaking.ConsensusKeys[](addrs.length);
        StakingLayout.ConsensusKeysStorage storage $ck = StakingLayout.consensusKeysStorage();
        for (uint256 i = 0; i < addrs.length; i++) {
            keys[i] = $ck.consensusKeys[addrs[i]];
        }
    }

    /// @notice Epoch-parameterized variant of getValidatorsWithKeys: the
    ///         stake-weighted keyed top-k set as of `epoch`. The executor uses
    ///         this to derive the committee for a future epoch it is about to
    ///         commit one epoch ahead (see commitEpochCommittee).
    function getValidatorsWithKeysAt(uint64 epoch)
        external
        view
        override
        returns (address[] memory addrs, IStaking.ConsensusKeys[] memory keys)
    {
        addrs = StakingLayout.getValidatorsAt(_chainConfigContract, epoch);
        keys = new IStaking.ConsensusKeys[](addrs.length);
        StakingLayout.ConsensusKeysStorage storage $ck = StakingLayout.consensusKeysStorage();
        for (uint256 i = 0; i < addrs.length; i++) {
            keys[i] = $ck.consensusKeys[addrs[i]];
        }
    }

    /// @notice The next epoch whose committee is not yet committed
    ///         (== lastCommittedEpochP1). The executor reads this to know which
    ///         epoch to derive + commit next in its ahead-of-time catch-up loop.
    function nextEpochToCommit() external view override returns (uint64) {
        return StakingLayout.epochCommitteeStorage().lastCommittedEpochP1;
    }

    /// @notice The epoch whose EffBal selects the next committee to commit:
    ///         `nextEpochToCommit() - 1` (0 at genesis). The executor passes this
    ///         to getValidatorsWithKeysAt so the derived committee matches the
    ///         contract's `_getValidatorsAt(selectionEpoch)` verification.
    function committeeSelectionEpoch() external view override returns (uint64) {
        uint64 target = StakingLayout.epochCommitteeStorage().lastCommittedEpochP1;
        return target == 0 ? 0 : target - 1;
    }

    function _slashValidator(address validatorAddress) internal {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        // make sure validator exists
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress));
        uint64 epoch = _currentEpoch();
        // increase slashes for current epoch
        ValidatorSnapshot storage currentSnapshot = _touchValidatorSnapshot(validator, epoch);
        uint32 slashesCount = currentSnapshot.slashesCount + 1;
        currentSnapshot.slashesCount = slashesCount;
        // validator state might change, lets update it
        $._validatorsMap[validatorAddress] = validator;
        // if validator has a lot of misses then put it in jail for 1 week (if epoch is 1 day)
        if (slashesCount == _chainConfigContract.getFelonyThreshold()) {
            validator.jailedBefore = _currentEpoch() + _chainConfigContract.getValidatorJailEpochLength();
            validator.status = ValidatorStatus.Jail;
            _removeValidatorFromActiveList(validatorAddress);
            $._validatorsMap[validatorAddress] = validator;
            emit ValidatorJailed(validatorAddress, epoch);
        }

        emit ValidatorSlashed(validatorAddress, slashesCount, epoch);
    }

    /// @notice Freezes the canonical consensus committee for the current epoch.
    /// @dev System call: the sequencer injects this once on the first block of
    ///      a new epoch (zero gas price, from coinbase), passing the SAME
    ///      ordered committee it feeds Commonware `Oracle::track`. The contract
    ///      does NOT trust that input: it verifies `committee` is exactly the
    ///      keyed subset of `_getValidators()` top-k, strictly ascending by
    ///      `peerPubkey` (the unique canonical Simplex committee order). The sequencer
    ///      has zero freedom — it can only submit the one array the contract
    ///      would itself derive; off-chain sorting just saves the O(m^2)
    ///      on-chain sort. Idempotent + strictly monotonic — a re-call for an
    ///      already/older epoch is a no-op; a missed epoch has no record (its
    ///      evidence is unslashable, by design).
    /// @param committee Validators in ascending-`peerPubkey` order. Reverts
    ///        unless it equals the keyed top-k set exactly.
    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function commitEpochCommittee(address[] calldata committee) external virtual override onlySystemCall {
        uint64 cur = _currentEpoch();
        // Commit the NEXT-uncommitted epoch, one epoch ahead. `lastCommittedEpochP1`
        // doubles as "next epoch to commit" (epochs 0..lastCommittedEpochP1-1 are
        // already committed; the genesis sentinel 0 ⇒ commit epoch 0).
        //
        // The gate `target <= cur + 1` is the snapshot-finality guarantee:
        // committee[target] reads snapshot[target-1], whose contributing delegations
        // come from epoch (target-1)-WARMUP_DELAY = target-3; with WARMUP_DELAY=2
        // those are final once cur >= target-1, i.e. target <= cur+1. Fail-loud
        // (revert): the executor's catch-up loop only calls within range, so an
        // out-of-range call is a bug.
        uint64 target = StakingLayout.epochCommitteeStorage().lastCommittedEpochP1;
        if (target > cur + 1) revert EpochNotYetCommittable(target, cur);
        uint64 selectionEpoch = target == 0 ? 0 : target - 1; // EffBal(target-1); cf. committeeSelectionEpoch()
        StakingDpos.commitEpochCommittee(_chainConfigContract, committee, target, cur, selectionEpoch);
    }

    /// @notice Resolves a Simplex signer index for a past epoch to the
    ///         validator address, using that epoch's frozen committee.
    function resolveSigner(uint64 epoch, uint32 signerIdx) external view override returns (address) {
        return _resolveSignerToValidator(epoch, signerIdx);
    }

    function _resolveSignerToValidator(uint64 epoch, uint32 signerIdx) internal view returns (address) {
        address[] storage c = StakingLayout.epochCommitteeStorage().committee[epoch];
        uint256 n = c.length;
        if (n == 0) revert EpochCommitteeNotCommitted(epoch);
        if (signerIdx >= n) revert SignerIndexOutOfRange(epoch, signerIdx, n);
        return c[signerIdx];
    }

    /// @notice Returns the frozen committee for `epoch` (Simplex committee order), or
    ///         empty if never committed. Consumed by fluent-staking-reader.
    function getEpochCommittee(uint64 epoch) external view override returns (address[] memory) {
        return StakingLayout.epochCommitteeStorage().committee[epoch];
    }

    function getEpochCommitteeLength(uint64 epoch) external view override returns (uint256) {
        return StakingLayout.epochCommitteeStorage().committee[epoch].length;
    }

    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function slashEquivocationNotarize(
        bytes calldata evidence,
        bytes calldata pkUncompressed,
        bytes calldata sig1Uncompressed,
        bytes calldata sig2Uncompressed
    ) external override {
        StakingDpos.slashEquivocationNotarize(
            _chainConfigContract, evidence, pkUncompressed, sig1Uncompressed, sig2Uncompressed
        );
    }

    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function slashEquivocationFinalize(
        bytes calldata evidence,
        bytes calldata pkUncompressed,
        bytes calldata sig1Uncompressed,
        bytes calldata sig2Uncompressed
    ) external override {
        StakingDpos.slashEquivocationFinalize(
            _chainConfigContract, evidence, pkUncompressed, sig1Uncompressed, sig2Uncompressed
        );
    }

    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function slashEquivocationNullifyFinalize(
        bytes calldata evidence,
        bytes calldata pkUncompressed,
        bytes calldata sig1Uncompressed,
        bytes calldata sig2Uncompressed
    ) external override {
        StakingDpos.slashEquivocationNullifyFinalize(
            _chainConfigContract, evidence, pkUncompressed, sig1Uncompressed, sig2Uncompressed
        );
    }
}
