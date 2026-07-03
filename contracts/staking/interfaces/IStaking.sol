// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IValidatorSet} from "./IValidatorSet.sol";

/**
 * @title IStakingEvents
 * @author Fluent Labs
 * @notice Lifecycle and accounting events emitted by the {Staking} contract.
 */
interface IStakingEvents {
    // ============ Validator lifecycle ============

    /**
     * @notice Emitted when a validator is registered or added via governance.
     * @dev `status` is the {IStaking.ValidatorStatus} encoded as `uint8`.
     */
    event ValidatorAdded(address indexed validator, address indexed owner, uint8 status, uint16 commissionRate);

    /**
     * @notice Emitted when a validator's metadata changes (activation, deactivation, commission update, owner rotation).
     * @dev `status` is the new {IStaking.ValidatorStatus} encoded as `uint8`; the prior status can be reconstructed
     *      from the prior {ValidatorAdded} or {ValidatorModified} event for the same validator.
     */
    event ValidatorModified(address indexed validator, address indexed owner, uint8 status, uint16 commissionRate);

    /**
     * @notice Emitted when a validator is removed from staking entirely.
     */
    event ValidatorRemoved(address indexed validator);

    /**
     * @notice Emitted when a jailed validator is released from jail after its jail period has elapsed.
     */
    event ValidatorReleased(address indexed validator, uint64 epoch);

    /**
     * @notice Emitted when a validator is jailed after crossing the felony slash threshold.
     */
    event ValidatorJailed(address indexed validator, uint64 epoch);

    /**
     * @notice Emitted when validator block rewards are deposited via the coinbase path.
     */
    event ValidatorDeposited(address indexed validator, uint256 amount, uint64 epoch);

    /**
     * @notice Emitted when a validator accrues a slash event.
     * @dev `slashes` is the new total slash count after this event is applied.
     */
    event ValidatorSlashed(address indexed validator, uint32 slashes, uint64 epoch);

    /**
     * @notice Emitted when a validator owner claims their accumulated commission.
     */
    event ValidatorOwnerClaimed(address indexed validator, uint256 amount, uint64 epoch);

    // ============ Delegator lifecycle ============

    /**
     * @notice Emitted when `staker` delegates `amount` to `validator` effective from `epoch`.
     */
    event Delegated(address indexed validator, address indexed staker, uint256 amount, uint64 epoch);

    /**
     * @notice Emitted when `staker` enqueues an undelegation of `amount` from `validator`.
     * @dev `epoch` is the epoch the undelegation request was created (not the maturity epoch).
     *      The maturity epoch is `epoch + IChainConfig.getUndelegatePeriod()`.
     */
    event Undelegated(address indexed validator, address indexed staker, uint256 amount, uint64 epoch);

    /**
     * @notice Emitted when `staker` claims `amount` (rewards plus any matured undelegations) from `validator`.
     */
    event Claimed(address indexed validator, address indexed staker, uint256 amount, uint64 epoch);

    /**
     * @notice Emitted when `staker` redelegates claimable rewards from `validator`.
     * @dev `amount` is the portion redelegated (compactable to staking precision); `dust` is the residual
     *      below precision that was transferred to the staker instead.
     */
    event Redelegated(address indexed validator, address indexed staker, uint256 amount, uint256 dust, uint64 epoch);
}

/**
 * @title IStakingErrors
 * @author Fluent Labs
 * @notice Custom errors raised by the {Staking} contract.
 */
interface IStakingErrors {
    /**
     * @notice Validator owner argument must not be the zero address.
     */
    error ZeroOwner();

    /**
     * @notice Validator address argument must not be the zero address.
     */
    error ZeroValidator();

    /**
     * @notice Validator commission rate must be greater than zero.
     */
    error ZeroCommissionRate();

    /**
     * @notice Initial validator self-stake must be greater than zero.
     */
    error ZeroInitialStake();

    /**
     * @notice Validator removal is blocked because the validator still has active delegations.
     * @param validator Validator whose delegation total is non-zero.
     */
    error ValidatorHasActiveDelegations(address validator);

    /**
     * @notice Epoch argument is out of the allowed range (e.g. registering a validator with a `sinceEpoch`
     *         that is past the next epoch boundary).
     */
    error InvalidEpoch();
}

/**
 * @title IStaking
 * @author Fluent Labs
 * @notice Manages validators, delegations, validator commission, delegator rewards, undelegation, and slashing.
 * @dev Implements the lower-level staking machinery used by {IStakingPool}, {ISlashingIndicator}, and
 *      governance. Validator state is snapshotted per epoch so reward accounting and slashing remain
 *      historically auditable.
 */
interface IStaking is IValidatorSet, IStakingEvents, IStakingErrors {
    /**
     * @notice Validator lifecycle states used by staking and active-set selection.
     */
    enum ValidatorStatus {
        /// @dev Validator is not registered with the staking contract.
        NotFound,
        /// @dev Validator is registered and eligible for active-set selection.
        Active,
        /// @dev Validator is registered but not yet eligible for the active set.
        Pending,
        /// @dev Validator is jailed after crossing the felony slash threshold; must be released after the jail window.
        Jail
    }

    /**
     * @notice Selects how matured delegator rewards are settled.
     */
    enum ClaimMode {
        /// @dev Transfer claimable rewards and matured undelegations to the delegator.
        Transfer,
        /// @dev Redelegate compactable rewards back into the same validator; transfer only the dust residual.
        Redelegate
    }

    /**
     * @notice Per-epoch validator accounting snapshot.
     * @dev Snapshots are written lazily when validator state mutates; readers materialize the latest
     *      snapshot when they need a historical view at a specific epoch.
     */
    struct ValidatorSnapshot {
        /// @dev Cumulative reward credited to the validator during the snapshot epoch.
        uint96 totalRewards;
        /// @dev Total delegated amount at the snapshot epoch, in compact precision units.
        uint112 totalDelegated;
        /// @dev Number of slashes accrued by the validator up to the snapshot epoch.
        uint32 slashesCount;
        /// @dev Commission rate active at the snapshot epoch, in basis points.
        uint16 commissionRate;
    }

    /**
     * @notice Mutable validator metadata independent of per-epoch accounting snapshots.
     */
    struct Validator {
        /// @dev Validator address (consensus identity).
        address validatorAddress;
        /// @dev Address authorized to administer the validator and claim its commission.
        address ownerAddress;
        /// @dev Current lifecycle state.
        ValidatorStatus status;
        /// @dev Epoch the validator metadata was last modified.
        uint64 changedAt;
        /// @dev Epoch before which the validator cannot be released from jail.
        uint64 jailedBefore;
        /// @dev Epoch up to which the owner has already claimed accrued commission.
        uint64 claimedAt;
        /// @dev Epoch of the validator's first snapshot; 0 for genesis validators.
        uint64 firstSnapshotEpoch;
    }

    /**
     * @notice Effective delegated amount at an epoch.
     */
    struct DelegationOpDelegate {
        /// @dev Delegated amount in compact precision units.
        uint112 amount;
        /// @dev Epoch the amount becomes effective.
        uint64 epoch;
    }

    /**
     * @notice Pending undelegation amount that matures at an epoch.
     */
    struct DelegationOpUndelegate {
        /// @dev Undelegation amount in compact precision units.
        uint112 amount;
        /// @dev Epoch the undelegation becomes claimable.
        uint64 epoch;
    }

    /**
     * @notice Delegation and undelegation queues for one delegator/validator pair.
     * @dev `delegateGap` and `undelegateGap` mark the head of each queue so processing can advance
     *      without shifting earlier (already-settled) entries.
     */
    struct ValidatorDelegation {
        /// @dev FIFO queue of delegate operations.
        DelegationOpDelegate[] delegateQueue;
        /// @dev Head index of `delegateQueue`; entries below it have already been settled.
        uint64 delegateGap;
        /// @dev FIFO queue of undelegate operations.
        DelegationOpUndelegate[] undelegateQueue;
        /// @dev Head index of `undelegateQueue`; entries below it have already been settled.
        uint64 undelegateGap;
    }

    // ============ Epochs ============

    /**
     * @notice Returns the epoch derived from the current block number.
     * @return epoch Current staking epoch.
     */
    function currentEpoch() external view returns (uint64 epoch);

    /**
     * @notice Returns the epoch immediately following {currentEpoch}.
     * @return epoch Next staking epoch.
     */
    function nextEpoch() external view returns (uint64 epoch);

    // ============ Validator status views ============

    /**
     * @notice Returns whether `validator` is currently in the active validator set.
     * @param validator Validator address to query.
     * @return active True when the validator is in the active set.
     */
    function isValidatorActive(address validator) external view returns (bool active);

    /**
     * @notice Returns whether `validator` is known to the staking contract in any status.
     * @param validator Validator address to query.
     * @return known True when the validator has any registered status other than {ValidatorStatus.NotFound}.
     */
    function isValidator(address validator) external view returns (bool known);

    /**
     * @notice Returns current validator metadata and latest accounting snapshot.
     * @param validator Validator address to query.
     * @return ownerAddress Owner of the validator.
     * @return status Current {ValidatorStatus} encoded as `uint8`.
     * @return totalDelegated Total delegated amount at the latest snapshot, in token precision.
     * @return slashesCount Cumulative slash count.
     * @return changedAt Epoch the validator metadata was last modified.
     * @return jailedBefore Epoch before which the validator cannot be released from jail.
     * @return claimedAt Epoch up to which the owner has claimed accrued commission.
     * @return commissionRate Commission rate at the latest snapshot, in basis points.
     * @return totalRewards Cumulative reward credited to the validator at the latest snapshot.
     */
    function getValidatorStatus(
        address validator
    )
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
        );

    /**
     * @notice Returns validator metadata with accounting materialized at `epoch`.
     * @dev Useful for historical analysis (rewards, slashes, commission) at a specific epoch boundary.
     * @param validator Validator address to query.
     * @param epoch Epoch to materialize the snapshot at.
     * @return ownerAddress Owner of the validator.
     * @return status {ValidatorStatus} encoded as `uint8` (status itself is current, not historical).
     * @return totalDelegated Total delegated amount at `epoch`.
     * @return slashesCount Slash count up to `epoch`.
     * @return changedAt Epoch the validator metadata was last modified.
     * @return jailedBefore Epoch before which the validator cannot be released from jail.
     * @return claimedAt Epoch up to which the owner has claimed accrued commission.
     * @return commissionRate Commission rate at `epoch`.
     * @return totalRewards Reward credited at `epoch`.
     */
    function getValidatorStatusAtEpoch(
        address validator,
        uint64 epoch
    )
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
        );

    /**
     * @notice Returns the validator address controlled by `owner`, or the zero address when none is registered.
     * @param owner Owner account to resolve.
     * @return validator Validator address owned by `owner`, or zero.
     */
    function getValidatorByOwner(address owner) external view returns (address validator);

    // ============ Validator administration ============

    /**
     * @notice Registers `validator` with `msg.sender` as owner and an initial self-stake.
     * @dev Pulls `initialStake` from `msg.sender` (prior ERC20 approval required). Emits
     *      {IStakingEvents-ValidatorAdded}.
     * @param validator Validator address being registered.
     * @param commissionRate Validator commission rate in basis points.
     * @param initialStake Self-stake delegated alongside the registration.
     */
    function registerValidator(address validator, uint16 commissionRate, uint256 initialStake) external;

    /**
     * @notice Adds a governance-managed validator (zero initial self-stake).
     * @dev Callable only by governance. Emits {IStakingEvents-ValidatorAdded}.
     * @param validator Validator address being added.
     */
    function addValidator(address validator) external;

    /**
     * @notice Removes a validator from staking.
     * @dev Reverts with {ValidatorHasActiveDelegations} when the validator still has delegations.
     *      Callable only by governance. Emits {IStakingEvents-ValidatorRemoved}.
     * @param validator Validator address being removed.
     */
    function removeValidator(address validator) external;

    /**
     * @notice Activates a known validator so it becomes eligible for the active set.
     * @dev Callable only by governance. Emits {IStakingEvents-ValidatorModified}.
     * @param validator Validator address being activated.
     */
    function activateValidator(address validator) external;

    /**
     * @notice Disables a validator without deleting its historical state.
     * @dev Callable only by governance. Emits {IStakingEvents-ValidatorModified}.
     * @param validator Validator address being disabled.
     */
    function disableValidator(address validator) external;

    /**
     * @notice Releases a jailed validator once its jail epoch has elapsed.
     * @dev Reverts with {IStakingContextErrors.StillInJail} when called too early. Emits
     *      {IStakingEvents-ValidatorReleased}.
     * @param validator Validator address being released.
     */
    function releaseValidatorFromJail(address validator) external;

    /**
     * @notice Updates the validator commission rate.
     * @dev Callable only by the validator owner. Emits {IStakingEvents-ValidatorModified}.
     * @param validator Validator address whose rate is being updated.
     * @param commissionRate New commission rate in basis points.
     */
    function changeValidatorCommissionRate(address validator, uint16 commissionRate) external;

    /**
     * @notice Transfers validator ownership to `newOwner`.
     * @dev Callable only by the current validator owner. Emits {IStakingEvents-ValidatorModified}.
     * @param validator Validator whose ownership is transferred.
     * @param newOwner Address that becomes the new owner.
     */
    function changeValidatorOwner(address validator, address newOwner) external;

    // ============ Delegation ============

    /**
     * @notice Returns the delegator's latest delegated amount and the epoch it became effective.
     * @param validator Validator the delegation targets.
     * @param delegator Delegator account being queried.
     * @return delegatedAmount Most recent delegated amount, in token precision.
     * @return atEpoch Epoch the latest delegation became effective.
     */
    function getValidatorDelegation(address validator, address delegator) external view returns (uint256 delegatedAmount, uint64 atEpoch);

    /**
     * @notice Delegates `amount` staking tokens to `validator`, effective from the next epoch.
     * @dev Pulls `amount` from `msg.sender` (prior ERC20 approval required) and appends an entry to
     *      the delegator's delegate queue. Emits {IStakingEvents-Delegated}.
     * @param validator Validator to delegate to.
     * @param amount Amount of staking tokens to delegate (must align to the staking compact precision).
     */
    function delegate(address validator, uint256 amount) external;

    /**
     * @notice Starts undelegation of `amount` from `validator` for `msg.sender`.
     * @dev Decreases the next-epoch delegation snapshot and enqueues an undelegate operation that
     *      matures after the configured undelegate period. Emits {IStakingEvents-Undelegated}.
     * @param validator Validator to undelegate from.
     * @param amount Amount to undelegate (must align to the staking compact precision).
     */
    function undelegate(address validator, uint256 amount) external;

    // ============ Validator owner fees ============

    /**
     * @notice Returns validator owner commission currently claimable.
     * @param validator Validator address to query.
     * @return amount Claimable commission, in token precision.
     */
    function getValidatorFee(address validator) external view returns (uint256 amount);

    /**
     * @notice Returns validator owner commission accrued but not yet claimable.
     * @param validator Validator address to query.
     * @return amount Pending commission, in token precision.
     */
    function getPendingValidatorFee(address validator) external view returns (uint256 amount);

    /**
     * @notice Settles all currently claimable validator owner commission and slashed system fees.
     * @dev Callable only by the validator owner. Emits {IStakingEvents-ValidatorOwnerClaimed}.
     * @param validator Validator address whose commission is settled.
     */
    function claimValidatorFee(address validator) external;

    /**
     * @notice Settles validator owner commission and slashed system fees accrued before `beforeEpoch`.
     * @dev Callable only by the validator owner. Useful when the full settlement would exceed the
     *      contract's per-call epoch cap.
     * @param validator Validator address whose commission is settled.
     * @param beforeEpoch Exclusive upper bound; only epochs strictly before this value are settled.
     */
    function claimValidatorFeeAtEpoch(address validator, uint64 beforeEpoch) external;

    // ============ Delegator fees and undelegations ============

    /**
     * @notice Returns delegator rewards and matured undelegations currently claimable.
     * @param validator Validator address to query.
     * @param delegator Delegator account being queried.
     * @return amount Claimable amount, in token precision.
     */
    function getDelegatorFee(address validator, address delegator) external view returns (uint256 amount);

    /**
     * @notice Returns delegator rewards accrued but not yet claimable.
     * @param validator Validator address to query.
     * @param delegator Delegator account being queried.
     * @return amount Pending rewards, in token precision.
     */
    function getPendingDelegatorFee(address validator, address delegator) external view returns (uint256 amount);

    /**
     * @notice Claims all currently claimable delegator rewards and matured undelegations.
     * @dev Settles both delegate-queue rewards and undelegate-queue principal in a single call.
     *      Emits {IStakingEvents-Claimed}.
     * @param validator Validator address whose entries are settled for `msg.sender`.
     */
    function claimDelegatorFee(address validator) external;

    /**
     * @notice Calculates the reward amount that can be compacted and redelegated without precision dust.
     * @dev Pure projection — does not mutate state. Splits the claimable amount into a precision-aligned
     *      slice that {redelegateDelegatorFee} would redelegate and the residual dust paid out to the delegator.
     * @param validator Validator address to query.
     * @param delegator Delegator account being queried.
     * @return delegatedAmount Portion that would be redelegated (compactable).
     * @return dustAmount Residual below the precision boundary.
     */
    function calcAvailableForRedelegateAmount(
        address validator,
        address delegator
    ) external view returns (uint256 delegatedAmount, uint256 dustAmount);

    /**
     * @notice Claims currently claimable delegator rewards and immediately redelegates the compactable portion.
     * @dev The residual dust is transferred to the delegator. Emits {IStakingEvents-Redelegated}.
     * @param validator Validator address whose rewards are redelegated for `msg.sender`.
     */
    function redelegateDelegatorFee(address validator) external;

    /**
     * @notice Claims delegator rewards and matured undelegations accrued before `beforeEpoch`.
     * @dev Useful when the full settlement would exceed the contract's per-call epoch cap.
     *      Emits {IStakingEvents-Claimed}.
     * @param validator Validator address whose entries are settled for `msg.sender`.
     * @param beforeEpoch Exclusive upper bound; only epochs strictly before this value are settled.
     */
    function claimDelegatorFeeAtEpoch(address validator, uint64 beforeEpoch) external;

    // ============ Slashing ============

    /**
     * @notice Applies a slash to `validator`.
     * @dev Callable only by the configured {ISlashingIndicator}. Jails the validator once the felony
     *      threshold is crossed. Emits {IStakingEvents-ValidatorSlashed} (and {IStakingEvents-ValidatorJailed}
     *      when the felony threshold trips).
     * @param validator Validator being slashed.
     */
    function slash(address validator) external;
}
