// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./StakingContext.sol";

/// @title Validator staking
/// @notice Manages validator registration, delegation, undelegation, commission, reward claims, active set ordering, and slashing.
/// @dev Uses epoch snapshots and compacted balances to preserve historical accounting without storing full uint256 stake values.
contract Staking is IStaking, StakingContext {
    using SafeERC20 for IERC20;

    // ERC-7201 storage namespace:
    // keccak256(abi.encode(uint256(keccak256("Fluent.storage.StakingStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STAKING_STORAGE_LOCATION =
        0x4102a9ba7244b40639ebe412c7bfc792b19c048efdf631bf4f130fef80c0df00;

    /**
     * This constant indicates precision of storing compact balances in the storage or floating point. Since default
     * balance precision is 256 bits it might gain some overhead on the storage because we don't need to store such huge
     * amount range. That is why we compact balances in uint112 values instead of uint256. By managing this value
     * you can set the precision of your balances, aka min and max possible staking amount. This value depends
     * mostly on your asset price in USD, for example ETH costs 4000$ then if we use 1 ether precision it takes 4000$
     * as min amount that might be problematic for users to do the stake. We can set 1 gwei precision and in this case
     * we increase min staking amount in 1e9 times, but also decreases max staking amount or total amount of staked assets.
     *
     * Here is an universal formula, if your asset is cheap in USD equivalent, like ~1$, then use 1 ether precision,
     * otherwise it might be better to use 1 gwei precision or any other amount that your want.
     *
     * Also be careful with setting `minValidatorStakeAmount` and `minStakingAmount`, because these values has
     * the same precision as specified here. It means that if you set precision 1 ether, then min staking amount of 10
     * tokens should have 10 raw value. For 1 gwei precision 10 tokens min amount should be stored as 10000000000.
     *
     * For the 112 bits we have ~32 decimals lg(2**112)=33.71 (lets round to 32 for simplicity). We split this amount
     * into integer (24) and for fractional (8) parts. It means that we can have only 8 decimals after zero.
     *
     * Based in current params we have next min/max values:
     * - min staking amount: 0.00000001 or 1e-8
     * - max staking amount: 1000000000000000000000000 or 1e+24
     *
     * WARNING: precision must be a 1eN format (A=1, N>0)
     */
    uint256 internal constant BALANCE_COMPACT_PRECISION = 1e10;
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
     * This gas limit is used for internal transfers to contracts that may execute expensive
     * fallback logic, such as transparent or beacon proxies with multiple SLOAD instructions.
     */
    uint64 internal constant TRANSFER_GAS_LIMIT = 30000;

    // validator events
    event ValidatorAdded(address indexed validator, address owner, uint8 status, uint16 commissionRate);
    event ValidatorModified(address indexed validator, address owner, uint8 status, uint16 commissionRate);
    event ValidatorRemoved(address indexed validator);
    event ValidatorOwnerClaimed(address indexed validator, uint256 amount, uint64 epoch);
    event ValidatorSlashed(address indexed validator, uint32 slashes, uint64 epoch);
    event ValidatorJailed(address indexed validator, uint64 epoch);
    event ValidatorDeposited(address indexed validator, uint256 amount, uint64 epoch);
    event ValidatorReleased(address indexed validator, uint64 epoch);

    // staker events
    event Delegated(address indexed validator, address indexed staker, uint256 amount, uint64 epoch);
    event Undelegated(address indexed validator, address indexed staker, uint256 amount, uint64 epoch);
    event Claimed(address indexed validator, address indexed staker, uint256 amount, uint64 epoch);
    event Redelegated(address indexed validator, address indexed staker, uint256 amount, uint256 dust, uint64 epoch);

    /// @notice Validator lifecycle states used by staking and active-set selection.
    enum ValidatorStatus {
        NotFound,
        Active,
        Pending,
        Jail
    }

    /// @notice Per-epoch validator accounting snapshot.
    struct ValidatorSnapshot {
        uint96 totalRewards;
        uint112 totalDelegated;
        uint32 slashesCount;
        uint16 commissionRate;
    }

    /// @notice Mutable validator metadata independent from per-epoch accounting snapshots.
    struct Validator {
        address validatorAddress;
        address ownerAddress;
        ValidatorStatus status;
        uint64 changedAt;
        uint64 jailedBefore;
        uint64 claimedAt;
    }

    /// @notice Effective delegated amount at an epoch.
    struct DelegationOpDelegate {
        uint112 amount;
        uint64 epoch;
    }

    /// @notice Pending undelegation amount that matures at an epoch.
    struct DelegationOpUndelegate {
        uint112 amount;
        uint64 epoch;
    }

    /// @notice Delegation and undelegation queues for one delegator/validator pair.
    struct ValidatorDelegation {
        DelegationOpDelegate[] delegateQueue;
        uint64 delegateGap;
        DelegationOpUndelegate[] undelegateQueue;
        uint64 undelegateGap;
    }

    /// @custom:storage-location erc7201:Fluent.storage.StakingStorage
    struct StakingStorage {
        // mapping from validator address to validator
        mapping(address => Validator) validatorsMap;
        // mapping from validator owner to validator address
        mapping(address => address) validatorOwners;
        // list of all validators that are in validators mapping
        address[] activeValidatorsList;
        // mapping with stakers to validators at epoch (validator -> delegator -> delegation)
        mapping(address => mapping(address => ValidatorDelegation)) validatorDelegations;
        // mapping with validator snapshots per each epoch (validator -> epoch -> snapshot)
        mapping(address => mapping(uint64 => ValidatorSnapshot)) validatorSnapshots;
    }

    function _getStakingStorage() private pure returns (StakingStorage storage $) {
        assembly {
            $.slot := STAKING_STORAGE_LOCATION
        }
    }

    constructor(
        IStaking stakingContract,
        ISlashingIndicator slashingIndicatorContract,
        ISystemReward systemRewardContract,
        IStakingPool stakingPoolContract,
        IGovernance governanceContract,
        IChainConfig chainConfigContract,
        IERC20 stakingToken
    )
        StakingContext(
            stakingContract,
            slashingIndicatorContract,
            systemRewardContract,
            stakingPoolContract,
            governanceContract,
            chainConfigContract,
            stakingToken
        )
    {}

    function initialize(
        address initialOwner,
        address[] calldata validators,
        uint256[] calldata initialStakes,
        uint16 commissionRate
    ) external initializer {
        __StakingContext_init(initialOwner);
        if (initialStakes.length != validators.length) revert MalformedInputLength();
        uint256 totalStakes = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            _addValidator(validators[i], validators[i], ValidatorStatus.Active, commissionRate, initialStakes[i], 0);
            totalStakes += initialStakes[i];
        }
        if (totalStakes > 0) {
            _stakingToken.safeTransferFrom(msg.sender, address(this), totalStakes);
        }
    }

    function getValidatorDelegation(address validatorAddress, address delegator)
        external
        view
        override
        returns (uint256 delegatedAmount, uint64 atEpoch)
    {
        StakingStorage storage $ = _getStakingStorage();
        ValidatorDelegation memory delegation = $.validatorDelegations[validatorAddress][delegator];
        if (delegation.delegateQueue.length == 0) {
            return (delegatedAmount = 0, atEpoch = 0);
        }
        DelegationOpDelegate memory snapshot = delegation.delegateQueue[delegation.delegateQueue.length - 1];
        return (delegatedAmount = uint256(snapshot.amount) * BALANCE_COMPACT_PRECISION, atEpoch = snapshot.epoch);
    }

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
        StakingStorage storage $ = _getStakingStorage();
        Validator memory validator = $.validatorsMap[validatorAddress];
        ValidatorSnapshot memory snapshot = $.validatorSnapshots[validator.validatorAddress][validator.changedAt];
        return (
            ownerAddress = validator.ownerAddress,
            status = uint8(validator.status),
            totalDelegated = uint256(snapshot.totalDelegated) * BALANCE_COMPACT_PRECISION,
            slashesCount = snapshot.slashesCount,
            changedAt = validator.changedAt,
            jailedBefore = validator.jailedBefore,
            claimedAt = validator.claimedAt,
            commissionRate = snapshot.commissionRate,
            totalRewards = snapshot.totalRewards
        );
    }

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
        StakingStorage storage $ = _getStakingStorage();
        Validator memory validator = $.validatorsMap[validatorAddress];
        ValidatorSnapshot memory snapshot = _touchValidatorSnapshotImmutable(validator, epoch);
        return (
            ownerAddress = validator.ownerAddress,
            status = uint8(validator.status),
            totalDelegated = uint256(snapshot.totalDelegated) * BALANCE_COMPACT_PRECISION,
            slashesCount = snapshot.slashesCount,
            changedAt = validator.changedAt,
            jailedBefore = validator.jailedBefore,
            claimedAt = validator.claimedAt,
            commissionRate = snapshot.commissionRate,
            totalRewards = snapshot.totalRewards
        );
    }

    function getValidatorByOwner(address owner) external view override returns (address) {
        StakingStorage storage $ = _getStakingStorage();
        return $.validatorOwners[owner];
    }

    function releaseValidatorFromJail(address validatorAddress) external {
        StakingStorage storage $ = _getStakingStorage();
        // make sure validator is in jail
        Validator memory validator = $.validatorsMap[validatorAddress];
        if (validator.status != ValidatorStatus.Jail) revert ValidatorNotInJail(validatorAddress);
        // only validator owner
        if (msg.sender != validator.ownerAddress) revert OnlyValidatorOwner(validator.ownerAddress);
        if (_currentEpoch() < validator.jailedBefore) revert StillInJail(validatorAddress);
        // update validator status
        validator.status = ValidatorStatus.Active;
        $.validatorsMap[validatorAddress] = validator;
        $.activeValidatorsList.push(validatorAddress);
        // emit event
        emit ValidatorReleased(validatorAddress, _currentEpoch());
    }

    function _totalDelegatedToValidator(Validator memory validator) internal view returns (uint256) {
        StakingStorage storage $ = _getStakingStorage();
        ValidatorSnapshot memory snapshot = $.validatorSnapshots[validator.validatorAddress][validator.changedAt];
        return uint256(snapshot.totalDelegated) * BALANCE_COMPACT_PRECISION;
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
        return uint64(block.number / _chainConfigContract.getEpochBlockInterval() + 0);
    }

    function _nextEpoch() internal view returns (uint64) {
        return _currentEpoch() + 1;
    }

    function _touchValidatorSnapshot(Validator memory validator, uint64 epoch)
        internal
        returns (ValidatorSnapshot storage)
    {
        StakingStorage storage $ = _getStakingStorage();
        ValidatorSnapshot storage snapshot = $.validatorSnapshots[validator.validatorAddress][epoch];
        // if snapshot is already initialized then just return it
        if (snapshot.totalDelegated > 0) {
            return snapshot;
        }
        // find previous snapshot to copy parameters from it
        ValidatorSnapshot memory lastModifiedSnapshot =
            $.validatorSnapshots[validator.validatorAddress][validator.changedAt];
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
        StakingStorage storage $ = _getStakingStorage();
        ValidatorSnapshot memory snapshot = $.validatorSnapshots[validator.validatorAddress][epoch];
        // if snapshot is already initialized then just return it
        if (snapshot.totalDelegated > 0) {
            return snapshot;
        }
        // find previous snapshot to copy parameters from it
        ValidatorSnapshot memory lastModifiedSnapshot =
            $.validatorSnapshots[validator.validatorAddress][validator.changedAt];
        // last modified snapshot might store zero value, for first delegation it might happen and its not critical
        snapshot.totalDelegated = lastModifiedSnapshot.totalDelegated;
        snapshot.commissionRate = lastModifiedSnapshot.commissionRate;
        // return existing or new snapshot
        return snapshot;
    }

    function _delegateTo(address fromDelegator, address toValidator, uint256 amount, bool pullTokens) internal {
        StakingStorage storage $ = _getStakingStorage();
        // check is minimum delegate amount
        if (amount < _chainConfigContract.getMinStakingAmount() || amount == 0) revert AmountTooLow(amount);
        if (amount % BALANCE_COMPACT_PRECISION != 0) revert WrongAmountPrecision();
        if (pullTokens) {
            _stakingToken.safeTransferFrom(fromDelegator, address(this), amount);
        }
        // make sure amount is greater than min staking amount
        // make sure validator exists at least
        Validator memory validator = $.validatorsMap[toValidator];
        if (validator.status == ValidatorStatus.NotFound) revert ValidatorNotFound(toValidator);
        uint64 atEpoch = _nextEpoch();
        // Lets upgrade next snapshot parameters:
        // + find snapshot for the next epoch after current block
        // + increase total delegated amount in the next epoch for this validator
        // + re-save validator because last affected epoch might change
        ValidatorSnapshot storage validatorSnapshot = _touchValidatorSnapshot(validator, atEpoch);
        validatorSnapshot.totalDelegated += uint112(amount / BALANCE_COMPACT_PRECISION);
        $.validatorsMap[toValidator] = validator;
        // if last pending delegate has the same next epoch then its safe to just increase total
        // staked amount because it can't affect current validator set, but otherwise we must create
        // new record in delegation queue with the last epoch (delegations are ordered by epoch)
        ValidatorDelegation storage delegation = $.validatorDelegations[toValidator][fromDelegator];
        if (delegation.delegateQueue.length > 0) {
            DelegationOpDelegate storage recentDelegateOp =
                delegation.delegateQueue[delegation.delegateQueue.length - 1];
            // if we already have pending snapshot for the next epoch then just increase new amount,
            // otherwise create next pending snapshot. (tbh it can't be greater, but what we can do here instead?)
            if (recentDelegateOp.epoch >= atEpoch) {
                recentDelegateOp.amount += uint112(amount / BALANCE_COMPACT_PRECISION);
            } else {
                delegation.delegateQueue
                    .push(
                        DelegationOpDelegate({
                            epoch: atEpoch,
                            amount: recentDelegateOp.amount + uint112(amount / BALANCE_COMPACT_PRECISION)
                        })
                    );
            }
        } else {
            // there is no any delegations at al, lets create the first one
            delegation.delegateQueue
                .push(DelegationOpDelegate({epoch: atEpoch, amount: uint112(amount / BALANCE_COMPACT_PRECISION)}));
        }
        // emit event with the next epoch
        emit Delegated(toValidator, fromDelegator, amount, atEpoch);
    }

    function _undelegateFrom(address toDelegator, address fromValidator, uint256 amount) internal {
        StakingStorage storage $ = _getStakingStorage();
        // check minimum delegate amount
        if (amount < _chainConfigContract.getMinStakingAmount() || amount == 0) revert AmountTooLow(amount);
        if (amount % BALANCE_COMPACT_PRECISION != 0) revert WrongAmountPrecision();
        // make sure validator exists at least
        Validator memory validator = $.validatorsMap[fromValidator];
        uint64 beforeEpoch = _nextEpoch();
        // Lets upgrade next snapshot parameters:
        // + find snapshot for the next epoch after current block
        // + increase total delegated amount in the next epoch for this validator
        // + re-save validator because last affected epoch might change
        ValidatorSnapshot storage validatorSnapshot = _touchValidatorSnapshot(validator, beforeEpoch);
        if (validatorSnapshot.totalDelegated < uint112(amount / BALANCE_COMPACT_PRECISION)) {
            revert InsufficientBalance();
        }
        validatorSnapshot.totalDelegated -= uint112(amount / BALANCE_COMPACT_PRECISION);
        $.validatorsMap[fromValidator] = validator;
        // if last pending delegate has the same next epoch then its safe to just increase total
        // staked amount because it can't affect current validator set, but otherwise we must create
        // new record in delegation queue with the last epoch (delegations are ordered by epoch)
        ValidatorDelegation storage delegation = $.validatorDelegations[fromValidator][toDelegator];
        if (delegation.delegateQueue.length == 0) revert DelegationQueueEmpty();
        DelegationOpDelegate storage recentDelegateOp = delegation.delegateQueue[delegation.delegateQueue.length - 1];
        if (recentDelegateOp.amount < uint64(amount / BALANCE_COMPACT_PRECISION)) revert InsufficientBalance();
        uint112 nextDelegatedAmount = recentDelegateOp.amount - uint112(amount / BALANCE_COMPACT_PRECISION);
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
                    amount: uint112(amount / BALANCE_COMPACT_PRECISION),
                    epoch: beforeEpoch + _chainConfigContract.getUndelegatePeriod()
                })
            );
        // emit event with the next epoch number
        emit Undelegated(fromValidator, toDelegator, amount, beforeEpoch);
    }

    enum ClaimMode {
        Transfer,
        Redelegate
    }

    function _claimDelegatorRewardsAndPendingUndelegates(
        address validator,
        address delegator,
        uint64 beforeEpochExclude,
        ClaimMode claimMode
    ) internal {
        StakingStorage storage $ = _getStakingStorage();
        ValidatorDelegation storage delegation = $.validatorDelegations[validator][delegator];
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
                ValidatorSnapshot memory validatorSnapshot = $.validatorSnapshots[validator][delegateOp.epoch];
                if (validatorSnapshot.totalDelegated == 0) {
                    continue;
                }
                (
                    uint256 delegatorFee,
                    /*uint256 ownerFee*/, /*uint256 systemFee*/
                ) = _calcValidatorSnapshotEpochPayout(validatorSnapshot);
                availableFunds += delegatorFee * delegateOp.amount / validatorSnapshot.totalDelegated;
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
            availableFunds += uint256(undelegateOp.amount) * BALANCE_COMPACT_PRECISION;
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
        StakingStorage storage $ = _getStakingStorage();
        ValidatorDelegation memory delegation = $.validatorDelegations[validator][delegator];
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
                ValidatorSnapshot memory validatorSnapshot = $.validatorSnapshots[validator][delegateOp.epoch];
                if (validatorSnapshot.totalDelegated == 0) {
                    continue;
                }
                (
                    uint256 delegatorFee,
                    /*uint256 ownerFee*/, /*uint256 systemFee*/
                ) = _calcValidatorSnapshotEpochPayout(validatorSnapshot);
                availableFunds += delegatorFee * delegateOp.amount / validatorSnapshot.totalDelegated;
            }
            ++delegation.delegateGap;
        }
        // process all items from undelegate queue
        while (delegation.undelegateGap < delegation.undelegateQueue.length) {
            DelegationOpUndelegate memory undelegateOp = delegation.undelegateQueue[delegation.undelegateGap];
            if (undelegateOp.epoch > beforeEpoch) {
                break;
            }
            availableFunds += uint256(undelegateOp.amount) * BALANCE_COMPACT_PRECISION;
            ++delegation.undelegateGap;
        }
        // return available for claim funds
        return availableFunds;
    }

    function _claimValidatorOwnerRewards(Validator storage validator, uint64 beforeEpoch) internal {
        StakingStorage storage $ = _getStakingStorage();
        uint256 availableFunds = 0;
        uint256 systemFee = 0;
        uint64 claimAt = validator.claimedAt;
        for (; claimAt < beforeEpoch; claimAt++) {
            ValidatorSnapshot memory validatorSnapshot = $.validatorSnapshots[validator.validatorAddress][claimAt];
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
        StakingStorage storage $ = _getStakingStorage();
        uint256 availableFunds = 0;
        for (; validator.claimedAt < beforeEpoch; validator.claimedAt++) {
            ValidatorSnapshot memory validatorSnapshot =
                $.validatorSnapshots[validator.validatorAddress][validator.claimedAt];
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
        // detect validator slashing to transfer all rewards to treasury
        if (validatorSnapshot.slashesCount >= _chainConfigContract.getMisdemeanorThreshold()) {
            return (delegatorFee = 0, ownerFee = 0, systemFee = validatorSnapshot.totalRewards);
        } else if (validatorSnapshot.totalDelegated == 0) {
            return (delegatorFee = 0, ownerFee = validatorSnapshot.totalRewards, systemFee = 0);
        }
        // ownerFee_(18+4-4=18) = totalRewards_18 * commissionRate_4 / 1e4
        ownerFee = uint256(validatorSnapshot.totalRewards) * validatorSnapshot.commissionRate / 1e4;
        // delegatorRewards = totalRewards - ownerFee
        delegatorFee = validatorSnapshot.totalRewards - ownerFee;
        // default system fee is zero for epoch
        systemFee = 0;
    }

    function registerValidator(address validatorAddress, uint16 commissionRate, uint256 initialStake)
        external
        override
    {
        // // initial stake amount should be greater than minimum validator staking amount
        if (initialStake < _chainConfigContract.getMinValidatorStakeAmount()) revert InitialStakeTooLow(initialStake);
        if (initialStake % BALANCE_COMPACT_PRECISION != 0) revert WrongAmountPrecision();
        _stakingToken.safeTransferFrom(msg.sender, address(this), initialStake);
        // add new validator as pending
        _addValidator(validatorAddress, msg.sender, ValidatorStatus.Pending, commissionRate, initialStake, _nextEpoch());
    }

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
        StakingStorage storage $ = _getStakingStorage();
        // validator commission rate
        if (commissionRate < COMMISSION_RATE_MIN_VALUE || commissionRate > COMMISSION_RATE_MAX_VALUE) {
            revert BadCommissionRate(commissionRate);
        }
        // init validator default params
        Validator memory validator = $.validatorsMap[validatorAddress];
        if ($.validatorsMap[validatorAddress].status != ValidatorStatus.NotFound) {
            revert ValidatorAlreadyExists(validatorAddress);
        }
        validator.validatorAddress = validatorAddress;
        validator.ownerAddress = validatorOwner;
        validator.status = status;
        validator.changedAt = sinceEpoch;
        $.validatorsMap[validatorAddress] = validator;
        // save validator owner
        if ($.validatorOwners[validatorOwner] != address(0x00)) revert ValidatorOwnerAlreadyInUse(validatorAddress);
        $.validatorOwners[validatorOwner] = validatorAddress;
        // add new validator to array
        if (status == ValidatorStatus.Active) {
            $.activeValidatorsList.push(validatorAddress);
        }
        // push initial validator snapshot at zero epoch with default params
        $.validatorSnapshots[validatorAddress][sinceEpoch] =
            ValidatorSnapshot(0, uint112(initialStake / BALANCE_COMPACT_PRECISION), 0, commissionRate);
        // delegate initial stake to validator owner
        ValidatorDelegation storage delegation = $.validatorDelegations[validatorAddress][validatorOwner];
        if (delegation.delegateQueue.length != 0) revert DelegationQueueNotEmpty(delegation.delegateQueue.length);
        delegation.delegateQueue
            .push(DelegationOpDelegate(uint112(initialStake / BALANCE_COMPACT_PRECISION), sinceEpoch));
        // emit event
        emit ValidatorAdded(validatorAddress, validatorOwner, uint8(status), commissionRate);
    }

    function removeValidator(address account) external virtual override onlyFromGovernance {
        _removeValidator(account);
    }

    function _removeValidatorFromActiveList(address validatorAddress) internal {
        StakingStorage storage $ = _getStakingStorage();
        // find index of validator in validator set
        int256 indexOf = -1;
        for (uint256 i = 0; i < $.activeValidatorsList.length; i++) {
            if ($.activeValidatorsList[i] != validatorAddress) continue;
            indexOf = int256(i);
            break;
        }
        // remove validator from array (since we remove only active it might not exist in the list)
        if (indexOf >= 0) {
            if ($.activeValidatorsList.length > 1 && uint256(indexOf) != $.activeValidatorsList.length - 1) {
                $.activeValidatorsList[uint256(indexOf)] = $.activeValidatorsList[$.activeValidatorsList.length - 1];
            }
            $.activeValidatorsList.pop();
        }
    }

    function _removeValidator(address validatorAddress) internal {
        StakingStorage storage $ = _getStakingStorage();
        Validator memory validator = $.validatorsMap[validatorAddress];
        if (validator.status == ValidatorStatus.NotFound) revert ValidatorNotFound(validatorAddress);
        // remove validator from active list if exists
        _removeValidatorFromActiveList(validatorAddress);
        // remove from validators map
        delete $.validatorOwners[validator.ownerAddress];
        delete $.validatorsMap[validatorAddress];
        // emit event about it
        emit ValidatorRemoved(validatorAddress);
    }

    function activateValidator(address validator) external virtual override onlyFromGovernance {
        _activateValidator(validator);
    }

    function _activateValidator(address validatorAddress) internal {
        StakingStorage storage $ = _getStakingStorage();
        Validator memory validator = $.validatorsMap[validatorAddress];
        if ($.validatorsMap[validatorAddress].status != ValidatorStatus.Pending) {
            revert NotPendingValidator(validatorAddress);
        }
        $.activeValidatorsList.push(validatorAddress);
        validator.status = ValidatorStatus.Active;
        $.validatorsMap[validatorAddress] = validator;
        ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(validator, _nextEpoch());
        emit ValidatorModified(
            validatorAddress, validator.ownerAddress, uint8(validator.status), snapshot.commissionRate
        );
    }

    function disableValidator(address validator) external virtual override onlyFromGovernance {
        _disableValidator(validator);
    }

    function _disableValidator(address validatorAddress) internal {
        StakingStorage storage $ = _getStakingStorage();
        Validator memory validator = $.validatorsMap[validatorAddress];
        if ($.validatorsMap[validatorAddress].status != ValidatorStatus.Active) {
            revert NotActiveValidator();
        }
        _removeValidatorFromActiveList(validatorAddress);
        validator.status = ValidatorStatus.Pending;
        $.validatorsMap[validatorAddress] = validator;
        ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(validator, _nextEpoch());
        emit ValidatorModified(
            validatorAddress, validator.ownerAddress, uint8(validator.status), snapshot.commissionRate
        );
    }

    function changeValidatorCommissionRate(address validatorAddress, uint16 commissionRate) external {
        StakingStorage storage $ = _getStakingStorage();
        if (commissionRate < COMMISSION_RATE_MIN_VALUE || commissionRate > COMMISSION_RATE_MAX_VALUE) {
            revert BadCommissionRate(commissionRate);
        }
        Validator memory validator = $.validatorsMap[validatorAddress];
        if (validator.status == ValidatorStatus.NotFound) revert ValidatorNotFound(validatorAddress);
        if (validator.ownerAddress != msg.sender) revert OnlyValidatorOwner(validator.ownerAddress);
        ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(validator, _nextEpoch());
        snapshot.commissionRate = commissionRate;
        $.validatorsMap[validatorAddress] = validator;
        emit ValidatorModified(
            validator.validatorAddress, validator.ownerAddress, uint8(validator.status), commissionRate
        );
    }

    function changeValidatorOwner(address validatorAddress, address newOwner) external override {
        StakingStorage storage $ = _getStakingStorage();
        Validator memory validator = $.validatorsMap[validatorAddress];
        if (validator.ownerAddress != msg.sender) revert OnlyValidatorOwner(validator.ownerAddress);
        if (newOwner == address(0)) revert OwnerCantBeZero();
        if ($.validatorOwners[newOwner] != address(0x00)) revert ValidatorOwnerAlreadyInUse(validatorAddress);
        delete $.validatorOwners[validator.ownerAddress];
        validator.ownerAddress = newOwner;
        $.validatorOwners[newOwner] = validatorAddress;
        $.validatorsMap[validatorAddress] = validator;
        ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(validator, _nextEpoch());
        emit ValidatorModified(
            validator.validatorAddress, validator.ownerAddress, uint8(validator.status), snapshot.commissionRate
        );
    }

    function isValidatorActive(address account) external view override returns (bool) {
        StakingStorage storage $ = _getStakingStorage();
        if ($.validatorsMap[account].status != ValidatorStatus.Active) {
            return false;
        }
        address[] memory topValidators = _getValidators();
        for (uint256 i = 0; i < topValidators.length; i++) {
            if (topValidators[i] == account) return true;
        }
        return false;
    }

    function isValidator(address account) external view override returns (bool) {
        StakingStorage storage $ = _getStakingStorage();
        return $.validatorsMap[account].status != ValidatorStatus.NotFound;
    }

    function _getValidators() internal view returns (address[] memory) {
        StakingStorage storage $ = _getStakingStorage();
        uint256 n = $.activeValidatorsList.length;
        address[] memory orderedValidators = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            orderedValidators[i] = $.activeValidatorsList[i];
        }
        // we need to select k top validators out of n
        uint256 k = _chainConfigContract.getActiveValidatorsLength();
        if (k > n) {
            k = n;
        }
        for (uint256 i = 0; i < k; i++) {
            uint256 nextValidator = i;
            Validator memory currentMax = $.validatorsMap[orderedValidators[nextValidator]];
            for (uint256 j = i + 1; j < n; j++) {
                Validator memory current = $.validatorsMap[orderedValidators[j]];
                if (_totalDelegatedToValidator(currentMax) < _totalDelegatedToValidator(current)) {
                    nextValidator = j;
                    currentMax = current;
                }
            }
            address backup = orderedValidators[i];
            orderedValidators[i] = orderedValidators[nextValidator];
            orderedValidators[nextValidator] = backup;
        }
        // this is to cut array to first k elements without copying
        assembly {
            mstore(orderedValidators, k)
        }
        return orderedValidators;
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
        StakingStorage storage $ = _getStakingStorage();
        if (amount == 0) revert DepositIsZero();
        _stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        // make sure validator is active
        Validator memory validator = $.validatorsMap[validatorAddress];
        if (validator.status == ValidatorStatus.NotFound) revert ValidatorNotFound(validatorAddress);
        uint64 epoch = _currentEpoch();
        // increase total pending rewards for validator for current epoch
        ValidatorSnapshot storage currentSnapshot = _touchValidatorSnapshot(validator, epoch);
        currentSnapshot.totalRewards += uint96(amount);
        // emit event
        emit ValidatorDeposited(validatorAddress, amount, epoch);
    }

    function getValidatorFee(address validatorAddress) external view override returns (uint256) {
        StakingStorage storage $ = _getStakingStorage();
        // make sure validator exists at least
        Validator memory validator = $.validatorsMap[validatorAddress];
        if (validator.status == ValidatorStatus.NotFound) {
            return 0;
        }
        // calc validator rewards
        return _calcValidatorOwnerRewards(validator, _currentEpoch());
    }

    function getPendingValidatorFee(address validatorAddress) external view override returns (uint256) {
        StakingStorage storage $ = _getStakingStorage();
        // make sure validator exists at least
        Validator memory validator = $.validatorsMap[validatorAddress];
        if (validator.status == ValidatorStatus.NotFound) {
            return 0;
        }
        // calc validator rewards
        return _calcValidatorOwnerRewards(validator, _nextEpoch());
    }

    function claimValidatorFee(address validatorAddress) external override {
        StakingStorage storage $ = _getStakingStorage();
        // make sure validator exists at least
        Validator storage validator = $.validatorsMap[validatorAddress];
        // only validator owner can claim deposit fee
        if (msg.sender != validator.ownerAddress) revert OnlyValidatorOwner(validator.ownerAddress);
        // claim all validator fees
        _claimValidatorOwnerRewards(validator, _currentEpoch());
    }

    function claimValidatorFeeAtEpoch(address validatorAddress, uint64 beforeEpoch) external override {
        StakingStorage storage $ = _getStakingStorage();
        // make sure validator exists at least
        Validator storage validator = $.validatorsMap[validatorAddress];
        // only validator owner can claim deposit fee
        if (msg.sender != validator.ownerAddress) revert OnlyValidatorOwner(validator.ownerAddress);
        // we disallow to claim rewards from future epochs
        if (beforeEpoch > _currentEpoch()) revert InvalidClaimEpoch();
        // claim all validator fees
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
        amountToStake = (claimableRewards / BALANCE_COMPACT_PRECISION) * BALANCE_COMPACT_PRECISION;
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
        if (beforeEpoch > _currentEpoch()) revert InvalidClaimEpoch();
        // claim all confirmed delegator fees including undelegates
        _claimDelegatorRewardsAndPendingUndelegates(validatorAddress, msg.sender, beforeEpoch, ClaimMode.Transfer);
    }

    function _safeTransfer(address recipient, uint256 amount) internal {
        if (amount > 0) {
            _stakingToken.safeTransfer(recipient, amount);
        }
    }

    function slash(address validatorAddress) external virtual override onlyFromSlashingIndicator {
        _slashValidator(validatorAddress);
    }

    function _slashValidator(address validatorAddress) internal {
        StakingStorage storage $ = _getStakingStorage();
        // make sure validator exists
        Validator memory validator = $.validatorsMap[validatorAddress];
        if (validator.status == ValidatorStatus.NotFound) revert ValidatorNotFound(validatorAddress);
        uint64 epoch = _currentEpoch();
        // increase slashes for current epoch
        ValidatorSnapshot storage currentSnapshot = _touchValidatorSnapshot(validator, epoch);
        uint32 slashesCount = currentSnapshot.slashesCount + 1;
        currentSnapshot.slashesCount = slashesCount;
        // validator state might change, lets update it
        $.validatorsMap[validatorAddress] = validator;
        // if validator has a lot of misses then put it in jail for 1 week (if epoch is 1 day)
        if (slashesCount == _chainConfigContract.getFelonyThreshold()) {
            validator.jailedBefore = _currentEpoch() + _chainConfigContract.getValidatorJailEpochLength();
            validator.status = ValidatorStatus.Jail;
            _removeValidatorFromActiveList(validatorAddress);
            $.validatorsMap[validatorAddress] = validator;
            emit ValidatorJailed(validatorAddress, epoch);
        }
        // emit event
        emit ValidatorSlashed(validatorAddress, slashesCount, epoch);
    }
}
