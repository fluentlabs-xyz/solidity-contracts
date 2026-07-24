// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IValidatorSet} from "./IValidatorSet.sol";

interface IStakingEvents {
    // validator events
    event ValidatorAdded(address indexed validator, address indexed owner, uint8 status, uint16 commissionRate);
    event ValidatorModified(address indexed validator, address indexed owner, uint8 status, uint16 commissionRate);
    event ValidatorRemoved(address indexed validator);
    event ValidatorReleased(address indexed validator, uint64 epoch);
    event ValidatorJailed(address indexed validator, uint64 epoch);
    event ValidatorSlashed(address indexed validator, uint32 slashes, uint64 epoch);
    /// @notice A participation-floor jail was NOT applied because it would drop the healthy active set
    ///         below the running committee's Simplex quorum `q(n)=n-f`, `n = min(activeSetSize, cap)`. A
    ///         laggy validator is kept in-committee in preference to a chain halt.
    event LivenessJailSkippedHaltGuard(
        address indexed validator, uint64 epoch, uint256 activeSetSize, uint256 quorumFloor
    );
    event ValidatorOwnerClaimed(address indexed validator, uint256 amount, uint64 epoch);

    // reward crediting events (per-epoch BLEND settlement)
    event EpochBlendRewardsCommitted(uint64 indexed epoch, uint256 blendAmount);
    /// @notice A finalized epoch was settled but credited zero stipend (empty / below-floor / partitioned
    ///         window) while the stipend was enabled — a genuinely forfeited window, surfaced for ops.
    ///         No carry-forward: the unpaid pot simply stays in the reserve.
    event StipendSkipped(uint64 indexed epoch);

    // consensus / equivocation events
    event ConsensusKeysSet(address indexed validator, bytes blsPubkey, bytes32 peerPubkey, uint64 activationEpoch);
    event EpochCommitteeCommitted(uint64 indexed epoch, address[] committee);
    /// @notice A DKG qualification was recorded for `epoch`'s committee (first write
    ///         only; idempotent re-submits do not re-emit). Gates the deferred
    ///         CHANGE-epoch committee commit: present ⇒ commit candidate, absent ⇒
    ///         carry incumbent.
    event DkgQualRecorded(uint64 indexed epoch);
    event EquivocationSlashed(address indexed validator, uint64 epoch, address indexed reporter);
    /// @param recipient Where the non-reporter `remainder` was sent: the governance-set
    ///        damage-coverage fund (`ChainConfig.getSlashFundAddress()`) when configured, else the
    ///        burn sink (`0x…dEaD`).
    event EquivocationStakeSeized(
        address indexed validator,
        address indexed reporter,
        uint256 reporterReward,
        uint256 remainder,
        address recipient
    );

    // staker events
    event Delegated(address indexed validator, address indexed staker, uint256 amount, uint64 epoch);
    event Undelegated(address indexed validator, address indexed staker, uint256 amount, uint64 epoch);
    event Claimed(address indexed validator, address indexed staker, uint256 amount, uint64 epoch);
    event Redelegated(address indexed validator, address indexed staker, uint256 amount, uint256 dust, uint64 epoch);
}

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

/// @title Validator staking interface
/// @notice Manages validators, delegations, validator commission, delegator rewards, undelegation, and slashing.
interface IStaking is IValidatorSet, IStakingEvents, IStakingErrors {
    /// @notice Validator lifecycle states used by staking and active-set selection.
    enum ValidatorStatus {
        NotFound,
        Active,
        Pending,
        Jail
    }

    /// @notice Per-epoch validator accounting snapshot.
    struct ValidatorSnapshot {
        uint112 totalDelegated;
        uint32 slashesCount;
        uint16 commissionRate;
        // Per-epoch BLEND reward ledger (the flat-by-stake stipend). Never copied forward by
        // touchValidatorSnapshot, so per-epoch credit is double-count-safe.
        uint96 totalBlendRewards;
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

    enum ClaimMode {
        Transfer,
        Redelegate
    }

    /// @notice Validator's consensus identity: BLS signing key + Ed25519 peer key.
    struct ConsensusKeys {
        bytes blsPubkey;
        bytes32 peerPubkey;
        uint64 activationEpoch;
    }

    /// @notice Returns the epoch derived from the current block number.
    function currentEpoch() external view returns (uint64);

    /// @notice Returns the next epoch after `currentEpoch()`.
    function nextEpoch() external view returns (uint64);

    /// @notice Returns whether `validator` is currently in the active validator set.
    function isValidatorActive(address validator) external view returns (bool);

    /// @notice Returns whether `validator` is known to the staking contract in any status.
    function isValidator(address validator) external view returns (bool);

    /// @notice Returns current validator metadata and latest accounting snapshot.
    function getValidatorStatus(address validator)
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
            uint16 commissionRate
        );

    /// @notice Returns `validator`'s effective delegated stake (voting power) as of `blockNumber`.
    /// @dev Uses the REBASED epoch (`dposActivationBlock`-relative, matching
    ///      {currentEpoch}) and the at-or-before snapshot — the same effective-stake
    ///      source committee selection ranks by. This is the canonical governance
    ///      voting-power read; it does not leak the validator's latest `changedAt`
    ///      snapshot for empty epochs, so a past `blockNumber` resolves to the stake
    ///      actually effective then rather than the validator's latest stake.
    function getValidatorDelegatedStakeAt(address validator, uint256 blockNumber) external view returns (uint256);

    /// @notice Returns the validator address owned by `owner`, or zero when none is registered.
    function getValidatorByOwner(address owner) external view returns (address);

    /// @notice Registers `validator` with `msg.sender` as owner and an initial self-stake.
    function registerValidator(address validator, uint16 commissionRate, uint256 initialStake) external;

    /// @notice Adds a governance-managed validator.
    function addValidator(address validator) external;

    /// @notice Removes a validator from staking.
    function removeValidator(address validator) external;

    /// @notice Activates a known validator.
    function activateValidator(address validator) external;

    /// @notice Disables a validator without deleting its historical state.
    function disableValidator(address validator) external;

    /// @notice Releases a jailed validator once its jail epoch has elapsed.
    function releaseValidatorFromJail(address validator) external;

    /// @notice Auto-reinstates every validator whose LIVENESS jail has expired
    ///         (`currentEpoch >= jailedBefore`), re-adding it to the active set with no owner
    ///         action. Tombstoned (equivocation) validators are popped, never readmitted.
    ///         Callable only by the `LivenessSlashing` predeploy; driven at the epoch boundary.
    function readmitExpiredJails(uint64 currentEpoch) external;

    /// @notice Updates validator commission rate.
    function changeValidatorCommissionRate(address validator, uint16 commissionRate) external;

    /// @notice Transfers validator ownership to `newOwner`.
    function changeValidatorOwner(address validator, address newOwner) external;

    /// @notice Returns a delegator's latest delegated amount and the epoch it became effective.
    function getValidatorDelegation(address validator, address delegator)
        external
        view
        returns (uint256 delegatedAmount, uint64 atEpoch);

    /// @notice Delegates `amount` staking tokens to `validator`, effective from the next epoch.
    function delegate(address validator, uint256 amount) external;

    /// @notice Starts undelegation of `amount` from `validator` for `msg.sender`.
    function undelegate(address validator, uint256 amount) external;

    /// @notice Returns validator owner commission currently claimable.
    function getValidatorFee(address validator) external view returns (uint256);

    /// @notice Returns validator owner commission accrued but not yet claimable.
    function getPendingValidatorFee(address validator) external view returns (uint256);

    /// @notice Settles all currently claimable validator owner commission and slashed system fees.
    function claimValidatorFee(address validator) external;

    /// @notice Settles validator owner commission and slashed system fees accrued before `beforeEpoch`.
    function claimValidatorFeeAtEpoch(address validator, uint64 beforeEpoch) external;

    /// @notice Returns delegator rewards and matured undelegations currently claimable.
    function getDelegatorFee(address validator, address delegator) external view returns (uint256);

    /// @notice Returns delegator rewards accrued but not yet claimable.
    function getPendingDelegatorFee(address validator, address delegator) external view returns (uint256);

    /// @notice Claims all currently claimable delegator rewards and matured undelegations.
    function claimDelegatorFee(address validator) external;

    /// @notice Calculates reward amount that can be compacted and redelegated without precision dust.
    function calcAvailableForRedelegateAmount(address validator, address delegator)
        external
        view
        returns (uint256 delegatedAmount, uint256 dustAmount);

    /// @notice Claims currently claimable delegator rewards and immediately redelegates compactable amount.
    function redelegateDelegatorFee(address validator) external;

    /// @notice Claims delegator rewards and matured undelegations accrued before `beforeEpoch`.
    function claimDelegatorFeeAtEpoch(address validator, uint64 beforeEpoch) external;

    /// @notice Applies a slash to `validator` for sustained liveness misses;
    ///         callable only by the `LivenessSlashing` predeploy. Reuses
    ///         the standard jail/felony pipeline.
    function slash(address validator) external;

    /// @notice Settle the per-epoch BLEND stipend (flat-by-stake among the live/active committee,
    ///         drawn from the `BlendReserve` and credited to the ledger). System call, injected at the
    ///         epoch boundary; idempotent per epoch.
    function settleEpochStipend(uint64 epoch) external;

    /// @notice Total BLEND reward credited across `epoch`'s committee, summed for an off-chain APR
    ///         basis. Read-only.
    function getEpochRewards(uint64 epoch) external view returns (uint256 blendTotal);

    /// @notice Sets consensus keys for `validator` with on-chain
    ///         Proof-of-Possession (one-shot, no rotation in v1). The
    ///         compressed pubkey is derived on-chain from
    ///         `blsPubkeyUncompressed` and stored.
    function setConsensusKeys(
        address validator,
        bytes calldata blsPubkeyUncompressed,
        bytes calldata blsPoPUncompressed,
        bytes32 peerPubkey
    ) external;

    /// @notice Returns consensus keys for `validator`, or empty struct if not set.
    function getConsensusKeys(address validator) external view returns (ConsensusKeys memory);

    /// @notice Returns active validators with their consensus keys in a single call.
    function getValidatorsWithKeys() external view returns (address[] memory addrs, ConsensusKeys[] memory keys);

    /// @notice The FULL Active-status validator registry (`_activeValidatorsList`)
    ///         with consensus keys — unlike {getValidatorsWithKeys}, NOT truncated
    ///         to the stake-weighted top-k committee. Feeds the consensus p2p
    ///         tier-2 peer set: every activated validator (in or out of the
    ///         committee, including the sequencer) stays connected.
    function getRegistryWithKeys() external view returns (address[] memory addrs, ConsensusKeys[] memory keys);

    /// @notice Epoch-parameterized variant of {getValidatorsWithKeys}: the
    ///         stake-weighted keyed top-k set as of `epoch`. Used by the executor to
    ///         derive the committee for the epoch it commits one ahead.
    function getValidatorsWithKeysAt(uint64 epoch)
        external
        view
        returns (address[] memory addrs, ConsensusKeys[] memory keys);

    /// @notice The next epoch whose committee is not yet committed (commit cursor).
    function nextEpochToCommit() external view returns (uint64);

    /// @notice The epoch whose effective stake (EffBal) selects the next committee
    ///         to commit: `nextEpochToCommit() - 1` (0 at genesis). The executor
    ///         passes this to {getValidatorsWithKeysAt}.
    function committeeSelectionEpoch() external view returns (uint64);

    /// @notice Freezes the canonical consensus committee one epoch ahead (system
    ///         call): commits the next-uncommitted epoch `N = nextEpochToCommit()`,
    ///         selecting it from `EffBal(N-2)` (2-epoch warm-up). `committee` must be the
    ///         keyed top-k set in strict ascending `peerPubkey` order; the contract
    ///         verifies it. Reverts if `N > currentEpoch + 2`.
    function commitEpochCommittee(address[] calldata committee) external;

    /// @notice Whether a committee MINT (a genuine membership change vs the incumbent, so
    ///         a fresh beacon key is dealt) was recorded for `epoch`. Set DETERMINISTICALLY
    ///         at commit time by `commitEpochCommittee` (`committee[epoch] !=
    ///         committee[epoch-1]`); the consensus beacon-key carry arbiter reads it to
    ///         find the newest key epoch. (Replaces the former permissionless
    ///         `recordDkgQual` marker.)
    function getDkgQual(uint64 epoch) external view returns (bool);

    /// @notice Resolves a Simplex signer index (for `epoch`) to a validator address.
    function resolveSigner(uint64 epoch, uint32 signerIdx) external view returns (address);

    /// @notice Returns the frozen committee for `epoch` in Simplex committee order (empty if uncommitted).
    function getEpochCommittee(uint64 epoch) external view returns (address[] memory);

    /// @notice Length of the frozen committee for `epoch` (0 if uncommitted).
    /// @dev A single SLOAD — avoids copying the whole committee array to memory
    ///      just to read its length (the per-block `processBitmap` hot path).
    function getEpochCommitteeLength(uint64 epoch) external view returns (uint256);

    /// @notice Frozen committee for `epoch` (Simplex order) with each member's keys
    ///         and frozen effective stake (wei). One atomic per-epoch snapshot read
    ///         for stake-weighted leader election. Empty arrays if uncommitted.
    /// @dev `stakes[i]` is full-precision wei (`totalDelegatedToValidatorAt`, the
    ///      at-or-before-`epoch` snapshot — the same source committee selection
    ///      ranks by, never the validator's unclamped latest `changedAt` read).
    function getEpochCommitteeWithStakes(uint64 epoch)
        external
        view
        returns (address[] memory addrs, ConsensusKeys[] memory keys, uint256[] memory stakes);

    /// @notice Permissionlessly slash a validator for a `ConflictingNotarize`
    ///         equivocation (two conflicting Notarize votes, same round/signer).
    function slashEquivocationNotarize(
        bytes calldata evidence,
        bytes calldata pkUncompressed,
        bytes calldata sig1Uncompressed,
        bytes calldata sig2Uncompressed
    ) external;

    /// @notice Permissionlessly slash a validator for a `ConflictingFinalize`
    ///         equivocation (two conflicting Finalize votes, same round/signer).
    function slashEquivocationFinalize(
        bytes calldata evidence,
        bytes calldata pkUncompressed,
        bytes calldata sig1Uncompressed,
        bytes calldata sig2Uncompressed
    ) external;

    /// @notice Permissionlessly slash a validator for a `NullifyFinalize`
    ///         equivocation (a Nullify and a Finalize, same round/signer).
    function slashEquivocationNullifyFinalize(
        bytes calldata evidence,
        bytes calldata pkUncompressed,
        bytes calldata sig1Uncompressed,
        bytes calldata sig2Uncompressed
    ) external;
}
