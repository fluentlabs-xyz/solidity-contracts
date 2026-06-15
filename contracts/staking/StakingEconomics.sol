// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStaking, IStakingEvents} from "./interfaces/IStaking.sol";
import {IStakingContextErrors} from "./interfaces/IStakingContext.sol";
import {IChainConfig} from "./interfaces/IChainConfig.sol";
import {ISystemReward} from "./interfaces/ISystemReward.sol";
import {StakingLayout} from "./StakingLayout.sol";

/// @title Staking economics extraction library
/// @author Fluent Labs
/// @notice Delegation + reward/fee accounting + claims relocated out of `Staking`
///         to keep its runtime bytecode under the EIP-170 24 KB limit. Reached by
///         DELEGATECALL from `Staking`'s thin forwarders, so it shares the proxy's
///         `msg.sender`, `address(this)`, and ERC-7201 storage.
/// @dev Library code under DELEGATECALL reads its OWN (empty) immutables, so it
///      cannot see `Staking`'s `_chainConfigContract` / `_stakingToken` /
///      `_systemRewardContract` — those dependencies are threaded in as the
///      `cfg` / `token` / `sysReward` parameters. Errors live in
///      `IStakingContextErrors`; events are emitted via `IStakingEvents`. The
///      shared snapshot helper lives in `StakingLayout` (single source).
library StakingEconomics {
    using SafeERC20 for IERC20;

    /// @dev Epoch math mirroring `Staking._currentEpoch`. `cfg` is passed in
    ///      because immutables are not reachable under DELEGATECALL (same form as
    ///      `StakingDpos._currentEpoch`).
    function _currentEpoch(IChainConfig cfg) internal view returns (uint64) {
        uint64 activation = cfg.getDposActivationBlock();
        if (block.number < activation) {
            return 0;
        }
        return uint64((block.number - activation) / cfg.getEpochBlockInterval());
    }

    function _nextEpoch(IChainConfig cfg) internal view returns (uint64) {
        return _currentEpoch(cfg) + 1;
    }

    // ---- external entrypoints (Staking forwards here) ----

    function delegate(IChainConfig cfg, IERC20 token, address validatorAddress, uint256 amount) external {
        _delegateTo(cfg, token, msg.sender, validatorAddress, amount, true);
    }

    function undelegate(IChainConfig cfg, address validatorAddress, uint256 amount) external {
        _undelegateFrom(cfg, msg.sender, validatorAddress, amount);
    }

    function getValidatorFee(IChainConfig cfg, address validatorAddress) external view returns (uint256) {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        // make sure validator exists at least
        IStaking.Validator memory validator = $._validatorsMap[validatorAddress];
        if (validator.status == IStaking.ValidatorStatus.NotFound) {
            return 0;
        }
        // calc validator rewards
        return _calcValidatorOwnerRewards(cfg, validator, _currentEpoch(cfg));
    }

    function getPendingValidatorFee(IChainConfig cfg, address validatorAddress) external view returns (uint256) {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        // make sure validator exists at least
        IStaking.Validator memory validator = $._validatorsMap[validatorAddress];
        if (validator.status == IStaking.ValidatorStatus.NotFound) {
            return 0;
        }
        // calc validator rewards
        return _calcValidatorOwnerRewards(cfg, validator, _nextEpoch(cfg));
    }

    function claimValidatorFee(IChainConfig cfg, IERC20 token, ISystemReward sysReward, address validatorAddress)
        external
    {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        // make sure validator exists at least
        IStaking.Validator storage validator = $._validatorsMap[validatorAddress];
        require(
            validator.status != IStaking.ValidatorStatus.NotFound,
            IStakingContextErrors.ValidatorNotFound(validatorAddress)
        );
        // settle all validator fees to the owner and slashed fees to the system reward contract
        _claimValidatorOwnerRewards(cfg, token, sysReward, validator, _currentEpoch(cfg));
    }

    function claimValidatorFeeAtEpoch(
        IChainConfig cfg,
        IERC20 token,
        ISystemReward sysReward,
        address validatorAddress,
        uint64 beforeEpoch
    ) external {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        // make sure validator exists at least
        IStaking.Validator storage validator = $._validatorsMap[validatorAddress];
        require(
            validator.status != IStaking.ValidatorStatus.NotFound,
            IStakingContextErrors.ValidatorNotFound(validatorAddress)
        );
        // we disallow to claim rewards from future epochs
        require(beforeEpoch <= _currentEpoch(cfg), IStakingContextErrors.InvalidClaimEpoch());
        // settle validator fees to the owner and slashed fees to the system reward contract
        _claimValidatorOwnerRewards(cfg, token, sysReward, validator, beforeEpoch);
    }

    function getDelegatorFee(IChainConfig cfg, address validatorAddress, address delegatorAddress)
        external
        view
        returns (uint256)
    {
        return _calcDelegatorRewardsAndPendingUndelegates(cfg, validatorAddress, delegatorAddress, _currentEpoch(cfg));
    }

    function getPendingDelegatorFee(IChainConfig cfg, address validatorAddress, address delegatorAddress)
        external
        view
        returns (uint256)
    {
        return _calcDelegatorRewardsAndPendingUndelegates(cfg, validatorAddress, delegatorAddress, _nextEpoch(cfg));
    }

    function claimDelegatorFee(IChainConfig cfg, IERC20 token, address validatorAddress) external {
        // claim all confirmed delegator fees including undelegates
        _claimDelegatorRewardsAndPendingUndelegates(
            cfg, token, validatorAddress, msg.sender, _currentEpoch(cfg), IStaking.ClaimMode.Transfer
        );
    }

    function claimDelegatorFeeAtEpoch(IChainConfig cfg, IERC20 token, address validatorAddress, uint64 beforeEpoch)
        external
    {
        // make sure delegator can't claim future epochs
        require(beforeEpoch <= _currentEpoch(cfg), IStakingContextErrors.InvalidClaimEpoch());
        // claim all confirmed delegator fees including undelegates
        _claimDelegatorRewardsAndPendingUndelegates(
            cfg, token, validatorAddress, msg.sender, beforeEpoch, IStaking.ClaimMode.Transfer
        );
    }

    function redelegateDelegatorFee(IChainConfig cfg, IERC20 token, address validator) external {
        // claim rewards in the redelegate mode (check function code for more info)
        _claimDelegatorRewardsAndPendingUndelegates(
            cfg, token, validator, msg.sender, _currentEpoch(cfg), IStaking.ClaimMode.Redelegate
        );
    }

    function calcAvailableForRedelegateAmount(IChainConfig cfg, address validator, address delegator)
        external
        view
        returns (uint256 amountToStake, uint256 rewardsDust)
    {
        uint256 claimableRewards =
            _calcDelegatorRewardsAndPendingUndelegates(cfg, validator, delegator, _currentEpoch(cfg));
        return _calcAvailableForRedelegateAmount(cfg, claimableRewards);
    }

    // ---- internal (inlined here; bodies relocated VERBATIM from Staking, with
    //      _currentEpoch()->_currentEpoch(cfg), _chainConfigContract->cfg,
    //      _stakingToken->token, _systemRewardContract->sysReward,
    //      _touchValidatorSnapshot->StakingLayout.touchValidatorSnapshot($,…)) ----

    function _delegateTo(
        IChainConfig cfg,
        IERC20 token,
        address fromDelegator,
        address toValidator,
        uint256 amount,
        bool pullTokens
    ) internal {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        // check is minimum delegate amount
        require(amount >= cfg.getMinStakingAmount() && amount > 0, IStakingContextErrors.AmountTooLow(amount));
        require(amount % StakingLayout.BALANCE_COMPACT_PRECISION == 0, IStakingContextErrors.WrongAmountPrecision());
        // make sure validator exists at least
        IStaking.Validator memory validator = $._validatorsMap[toValidator];
        require(
            validator.status != IStaking.ValidatorStatus.NotFound, IStakingContextErrors.ValidatorNotFound(toValidator)
        );
        uint64 atEpoch = _currentEpoch(cfg) + StakingLayout.WARMUP_DELAY; // warmup: effective at epoch e+2
        // Upgrade the warmup-target (e+2) snapshot:
        // + find snapshot for atEpoch (e+2)
        // + increase total delegated amount at atEpoch for this validator
        // + re-save validator because last affected epoch might change
        IStaking.ValidatorSnapshot storage validatorSnapshot =
            StakingLayout.touchValidatorSnapshot($, validator, atEpoch);
        validatorSnapshot.totalDelegated += uint112(amount / StakingLayout.BALANCE_COMPACT_PRECISION);
        $._validatorsMap[toValidator] = validator;
        // if last pending delegate has the same next epoch then its safe to just increase total
        // staked amount because it can't affect current validator set, but otherwise we must create
        // new record in delegation queue with the last epoch (delegations are ordered by epoch)
        IStaking.ValidatorDelegation storage delegation = $._validatorDelegations[toValidator][fromDelegator];
        if (delegation.delegateQueue.length > 0) {
            IStaking.DelegationOpDelegate storage recentDelegateOp =
                delegation.delegateQueue[delegation.delegateQueue.length - 1];
            // if we already have pending snapshot for the next epoch then just increase new amount,
            // otherwise create next pending snapshot. (tbh it can't be greater, but what we can do here instead?)
            if (recentDelegateOp.epoch >= atEpoch) {
                recentDelegateOp.amount += uint112(amount / StakingLayout.BALANCE_COMPACT_PRECISION);
            } else {
                delegation.delegateQueue
                    .push(
                        IStaking.DelegationOpDelegate({
                            epoch: atEpoch,
                            amount: recentDelegateOp.amount + uint112(amount / StakingLayout.BALANCE_COMPACT_PRECISION)
                        })
                    );
            }
        } else {
            // there is no any delegations at al, lets create the first one
            delegation.delegateQueue
                .push(
                    IStaking.DelegationOpDelegate({
                        epoch: atEpoch, amount: uint112(amount / StakingLayout.BALANCE_COMPACT_PRECISION)
                    })
                );
        }
        // CEI: pull tokens after all state updates. If the staking token ever becomes
        // callback-style (ERC-777), a reentrant re-entry would observe consistent state.
        if (pullTokens) {
            token.safeTransferFrom(fromDelegator, address(this), amount);
        }
        // emit event with the next epoch
        emit IStakingEvents.Delegated(toValidator, fromDelegator, amount, atEpoch);
    }

    function _undelegateFrom(IChainConfig cfg, address toDelegator, address fromValidator, uint256 amount) internal {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        // check minimum delegate amount
        require(amount >= cfg.getMinStakingAmount() && amount > 0, IStakingContextErrors.AmountTooLow(amount));
        require(amount % StakingLayout.BALANCE_COMPACT_PRECISION == 0, IStakingContextErrors.WrongAmountPrecision());
        // make sure validator exists at least
        IStaking.Validator memory validator = $._validatorsMap[fromValidator];
        require(
            validator.status != IStaking.ValidatorStatus.NotFound,
            IStakingContextErrors.ValidatorNotFound(fromValidator)
        );
        uint64 beforeEpoch = _nextEpoch(cfg);
        // Lets upgrade next snapshot parameters:
        // + find snapshot for the next epoch after current block
        // + increase total delegated amount in the next epoch for this validator
        // + re-save validator because last affected epoch might change
        IStaking.ValidatorSnapshot storage validatorSnapshot =
            StakingLayout.touchValidatorSnapshot($, validator, beforeEpoch);
        require(
            validatorSnapshot.totalDelegated >= uint112(amount / StakingLayout.BALANCE_COMPACT_PRECISION),
            IStakingContextErrors.InsufficientBalance()
        );
        validatorSnapshot.totalDelegated -= uint112(amount / StakingLayout.BALANCE_COMPACT_PRECISION);
        $._validatorsMap[fromValidator] = validator;
        // if last pending delegate has the same next epoch then its safe to just increase total
        // staked amount because it can't affect current validator set, but otherwise we must create
        // new record in delegation queue with the last epoch (delegations are ordered by epoch)
        IStaking.ValidatorDelegation storage delegation = $._validatorDelegations[fromValidator][toDelegator];
        require(delegation.delegateQueue.length > 0, IStakingContextErrors.DelegationQueueEmpty());
        IStaking.DelegationOpDelegate storage recentDelegateOp =
            delegation.delegateQueue[delegation.delegateQueue.length - 1];
        require(
            recentDelegateOp.amount >= uint112(amount / StakingLayout.BALANCE_COMPACT_PRECISION),
            IStakingContextErrors.InsufficientBalance()
        );
        uint112 nextDelegatedAmount =
            recentDelegateOp.amount - uint112(amount / StakingLayout.BALANCE_COMPACT_PRECISION);
        // Keep the owner self-stake above the validator minimum while other delegators remain.
        // If the owner is the sole remaining delegator, a full exit is allowed so governance can
        // remove the validator after the undelegation takes effect.
        if (
            toDelegator == validator.ownerAddress
                && (validator.status == IStaking.ValidatorStatus.Active
                    || validator.status == IStaking.ValidatorStatus.Pending)
        ) {
            uint256 selfStakeRemaining =
                uint256(nextDelegatedAmount) * StakingLayout.BALANCE_COMPACT_PRECISION;
            uint256 totalStakeRemaining =
                uint256(validatorSnapshot.totalDelegated) * StakingLayout.BALANCE_COMPACT_PRECISION;
            if (selfStakeRemaining < cfg.getMinValidatorStakeAmount() && totalStakeRemaining != selfStakeRemaining) {
                revert IStakingContextErrors.OwnerSelfStakeBelowMinimum();
            }
        }
        if (recentDelegateOp.epoch >= beforeEpoch) {
            // decrease total delegated amount for the next epoch
            recentDelegateOp.amount = nextDelegatedAmount;
        } else {
            // there is no pending delegations, so lets create the new one with the new amount
            delegation.delegateQueue
                .push(IStaking.DelegationOpDelegate({epoch: beforeEpoch, amount: nextDelegatedAmount}));
        }
        // create new undelegate queue operation with soft lock
        delegation.undelegateQueue
            .push(
                IStaking.DelegationOpUndelegate({
                    amount: uint112(amount / StakingLayout.BALANCE_COMPACT_PRECISION),
                    epoch: beforeEpoch + cfg.getUndelegatePeriod()
                })
            );
        // emit event with the next epoch number
        emit IStakingEvents.Undelegated(fromValidator, toDelegator, amount, beforeEpoch);
    }

    /**
     * @dev Returns `beforeEpoch` capped to the first unprocessed epoch plus `MAX_EPOCHS_PER_CLAIM`.
     *
     * The first unprocessed epoch is taken from the delegation queue head. If the delegation queue
     * is fully processed, the undelegation queue head is used instead.
     */
    function _cappedDelegatorClaimEpoch(IStaking.ValidatorDelegation storage delegation, uint64 beforeEpoch)
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
        uint64 cappedTo = firstUnprocessed + StakingLayout.MAX_EPOCHS_PER_CLAIM;
        return cappedTo < beforeEpoch ? cappedTo : beforeEpoch;
    }

    function _claimDelegatorRewardsAndPendingUndelegates(
        IChainConfig cfg,
        IERC20 token,
        address validator,
        address delegator,
        uint64 beforeEpochExclude,
        IStaking.ClaimMode claimMode
    ) internal {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        IStaking.ValidatorDelegation storage delegation = $._validatorDelegations[validator][delegator];
        // Bound the number of processed epochs; callers can repeat claims to drain longer ranges.
        beforeEpochExclude = _cappedDelegatorClaimEpoch(delegation, beforeEpochExclude);
        uint256 availableFunds = 0;
        // process delegate queue to calculate staking rewards
        uint64 delegateGap = delegation.delegateGap;
        for (uint256 queueLength = delegation.delegateQueue.length; delegateGap < queueLength;) {
            IStaking.DelegationOpDelegate memory delegateOp = delegation.delegateQueue[delegateGap];
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
                IStaking.ValidatorSnapshot memory validatorSnapshot = $._validatorSnapshots[validator][delegateOp.epoch];
                if (validatorSnapshot.totalDelegated == 0) {
                    continue;
                }
                (
                    uint256 delegatorFee,, /*uint256 ownerFee*/ /*uint256 systemFee*/
                ) = _calcValidatorSnapshotEpochPayout(cfg, validatorSnapshot);
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
            IStaking.DelegationOpUndelegate memory undelegateOp = delegation.undelegateQueue[undelegateGap];
            if (undelegateOp.epoch > beforeEpochExclude) {
                break;
            }
            availableFunds += uint256(undelegateOp.amount) * StakingLayout.BALANCE_COMPACT_PRECISION;
            delete delegation.undelegateQueue[undelegateGap];
            ++undelegateGap;
        }
        delegation.undelegateGap = undelegateGap;
        // send available for claim funds to delegator
        if (claimMode == IStaking.ClaimMode.Transfer) {
            // for transfer claim mode just all rewards to the user
            _safeTransfer(token, delegator, availableFunds);
            // emit event
            emit IStakingEvents.Claimed(validator, delegator, availableFunds, beforeEpochExclude);
        } else if (claimMode == IStaking.ClaimMode.Redelegate) {
            (uint256 amountToStake, uint256 rewardsDust) = _calcAvailableForRedelegateAmount(cfg, availableFunds);
            // if we have something to re-stake then delegate it to the validator
            if (amountToStake > 0) {
                _delegateTo(cfg, token, delegator, validator, amountToStake, false);
            }
            // if we have dust from staking then send it to user
            if (rewardsDust > 0) {
                _safeTransfer(token, delegator, rewardsDust);
            }
            // emit event
            emit IStakingEvents.Redelegated(validator, delegator, amountToStake, rewardsDust, beforeEpochExclude);
        } else {
            // this case is not possible, no error for less bytecode
            revert IStakingContextErrors.NotEnoughBalance();
        }
    }

    function _calcDelegatorRewardsAndPendingUndelegates(
        IChainConfig cfg,
        address validator,
        address delegator,
        uint64 beforeEpoch
    ) internal view returns (uint256) {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        IStaking.ValidatorDelegation memory delegation = $._validatorDelegations[validator][delegator];
        uint256 availableFunds = 0;
        // process delegate queue to calculate staking rewards
        while (delegation.delegateGap < delegation.delegateQueue.length) {
            IStaking.DelegationOpDelegate memory delegateOp = delegation.delegateQueue[delegation.delegateGap];
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
                IStaking.ValidatorSnapshot memory validatorSnapshot = $._validatorSnapshots[validator][delegateOp.epoch];
                if (validatorSnapshot.totalDelegated == 0) {
                    continue;
                }
                (
                    uint256 delegatorFee,, /*uint256 ownerFee*/ /*uint256 systemFee*/
                ) = _calcValidatorSnapshotEpochPayout(cfg, validatorSnapshot);
                availableFunds += (delegatorFee * delegateOp.amount) / validatorSnapshot.totalDelegated;
            }
            ++delegation.delegateGap;
        }
        // process all items from undelegate queue
        while (delegation.undelegateGap < delegation.undelegateQueue.length) {
            IStaking.DelegationOpUndelegate memory undelegateOp = delegation.undelegateQueue[delegation.undelegateGap];
            if (undelegateOp.epoch > beforeEpoch) {
                break;
            }
            availableFunds += uint256(undelegateOp.amount) * StakingLayout.BALANCE_COMPACT_PRECISION;
            ++delegation.undelegateGap;
        }
        // return available for claim funds
        return availableFunds;
    }

    function _claimValidatorOwnerRewards(
        IChainConfig cfg,
        IERC20 token,
        ISystemReward sysReward,
        IStaking.Validator storage validator,
        uint64 beforeEpoch
    ) internal {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        // Bound the number of processed epochs; owners can repeat claims to drain longer ranges.
        uint64 cappedTo = validator.claimedAt + StakingLayout.MAX_EPOCHS_PER_CLAIM;
        if (cappedTo < beforeEpoch) {
            beforeEpoch = cappedTo;
        }
        uint256 availableFunds = 0;
        uint256 systemFee = 0;
        uint64 claimAt = validator.claimedAt;
        for (; claimAt < beforeEpoch; claimAt++) {
            IStaking.ValidatorSnapshot memory validatorSnapshot =
                $._validatorSnapshots[validator.validatorAddress][claimAt];
            (/*uint256 delegatorFee*/, uint256 ownerFee, uint256 slashingFee) =
                _calcValidatorSnapshotEpochPayout(cfg, validatorSnapshot);
            availableFunds += ownerFee;
            systemFee += slashingFee;
        }
        validator.claimedAt = claimAt;
        _safeTransfer(token, validator.ownerAddress, availableFunds);
        // if we have system fee then pay it to treasury account
        if (systemFee > 0) {
            token.forceApprove(address(sysReward), systemFee);
            sysReward.deposit(systemFee);
        }
        emit IStakingEvents.ValidatorOwnerClaimed(validator.validatorAddress, availableFunds, beforeEpoch);
    }

    function _calcValidatorOwnerRewards(IChainConfig cfg, IStaking.Validator memory validator, uint64 beforeEpoch)
        internal
        view
        returns (uint256)
    {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        uint256 availableFunds = 0;
        for (; validator.claimedAt < beforeEpoch; validator.claimedAt++) {
            IStaking.ValidatorSnapshot memory validatorSnapshot =
                $._validatorSnapshots[validator.validatorAddress][validator.claimedAt];
            (
                /*uint256 delegatorFee*/,
                uint256 ownerFee, /*uint256 systemFee*/
            ) = _calcValidatorSnapshotEpochPayout(cfg, validatorSnapshot);
            availableFunds += ownerFee;
        }
        return availableFunds;
    }

    function _calcValidatorSnapshotEpochPayout(IChainConfig cfg, IStaking.ValidatorSnapshot memory validatorSnapshot)
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
        if (validatorSnapshot.slashesCount >= cfg.getMisdemeanorThreshold()) {
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

    function _calcAvailableForRedelegateAmount(IChainConfig cfg, uint256 claimableRewards)
        internal
        view
        returns (uint256 amountToStake, uint256 rewardsDust)
    {
        // for redelegate we must split amount into stake-able and dust
        amountToStake =
            (claimableRewards / StakingLayout.BALANCE_COMPACT_PRECISION) * StakingLayout.BALANCE_COMPACT_PRECISION;
        if (amountToStake < cfg.getMinStakingAmount()) {
            return (0, claimableRewards);
        }
        // if we have dust remaining after re-stake then send it to user (we can't keep it in the contract)
        return (amountToStake, claimableRewards - amountToStake);
    }

    function _safeTransfer(IERC20 token, address recipient, uint256 amount) internal {
        if (amount > 0) {
            token.safeTransfer(recipient, amount);
        }
    }
}
