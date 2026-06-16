// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IStaking} from "./interfaces/IStaking.sol";
import {IChainConfig} from "./interfaces/IChainConfig.sol";

/// @title Shared ERC-7201 storage layout for the staking module
/// @author Fluent Labs
/// @notice Single source of truth for the four namespaced storage regions so
///         both `Staking` and the linked `StakingDpos` library re-derive
///         identical slots. Centralizing the slot constants here removes the
///         silent-divergence hazard of duplicating them in the library: a
///         linked library reaching the same storage by re-declaring a slot
///         constant would corrupt state on a single mistyped hex digit, with
///         no compiler link between the two declarations.
library StakingLayout {
    /**
     * Single source of truth (shared by `Staking` delegation/reward math and the
     * selection sort below). This constant indicates precision of storing compact
     * balances in the storage or floating point. Since default balance precision
     * is 256 bits it might gain some overhead on the storage because we don't need
     * to store such huge amount range. That is why we compact balances in uint112
     * values instead of uint256. By managing this value you can set the precision
     * of your balances, aka min and max possible staking amount. This value depends
     * mostly on your asset price in USD, for example ETH costs 4000$ then if we use
     * 1 ether precision it takes 4000$ as min amount that might be problematic for
     * users to do the stake. We can set 1 gwei precision and in this case we
     * increase min staking amount in 1e9 times, but also decreases max staking
     * amount or total amount of staked assets.
     *
     * Here is an universal formula, if your asset is cheap in USD equivalent, like
     * ~1$, then use 1 ether precision, otherwise it might be better to use 1 gwei
     * precision or any other amount that your want.
     *
     * Also be careful with setting `minValidatorStakeAmount` and `minStakingAmount`,
     * because these values has the same precision as specified here. It means that
     * if you set precision 1 ether, then min staking amount of 10 tokens should
     * have 10 raw value. For 1 gwei precision 10 tokens min amount should be stored
     * as 10000000000.
     *
     * For the 112 bits we have ~32 decimals lg(2**112)=33.71 (lets round to 32 for
     * simplicity). We split this amount into integer (24) and for fractional (8)
     * parts. It means that we can have only 8 decimals after zero.
     *
     * Based in current params we have next min/max values:
     * - min staking amount: 0.00000001 or 1e-8
     * - max staking amount: 1000000000000000000000000 or 1e+24
     *
     * WARNING: precision must be a 1eN format (A=1, N>0)
     */
    uint256 internal constant BALANCE_COMPACT_PRECISION = 1e10;

    /// @notice Two-epoch warmup: stake delegated in epoch e becomes effective at
    ///         e+2 (PoS spec §4.2). This depth is what lets the committee for epoch
    ///         N be selected one epoch ahead. committee[N] is selected from
    ///         EffBal(N-1) = snapshot[N-1] (§4.4); with WARMUP_DELAY=2 its
    ///         contributing delegations come from epoch (N-1)-WARMUP_DELAY = N-3, so
    ///         snapshot[N-1] is final by the first block of epoch N-1 — see
    ///         commitEpochCommittee's `target <= currentEpoch+1` gate. Shared by
    ///         `Staking` and `StakingEconomics`; single source.
    uint64 internal constant WARMUP_DELAY = 2;

    /**
     * @dev Maximum number of epochs processed by a single state-changing claim.
     *
     * This bounds reward and undelegation iteration so accounts with long unclaimed ranges can
     * settle progressively instead of requiring one transaction to process the entire history.
     * Shared by `Staking` and `StakingEconomics`; single source.
     */
    uint64 internal constant MAX_EPOCHS_PER_CLAIM = 1000;

    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.StakingStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant STAKING_STORAGE_LOCATION =
        0x4102a9ba7244b40639ebe412c7bfc792b19c048efdf631bf4f130fef80c0df00;

    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.ConsensusKeysStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant CONSENSUS_KEYS_STORAGE_LOCATION =
        0xf295d610a4116363064013aa5e1168427c6b907b208d8be559665c0e7adec500;

    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.EpochCommitteeStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant EPOCH_COMMITTEE_STORAGE_LOCATION =
        0x8f1c49778ec45f03e87f0e3e1567785ab335a882d8dad6d5c44cb7ae50968400;

    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.EquivocationStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant EQUIVOCATION_STORAGE_LOCATION =
        0x96610efdc8a37de390ea3757bf0331faa3a74708adc53f30ba708302b0f55800;

    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.EpochBeaconStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant EPOCH_BEACON_STORAGE_LOCATION =
        0xd9eff1b8c318f0d144ec006a3ad306d57c34b8d91ebd3ec67df12b9551f47c00;

    /// @custom:storage-location erc7201:Fluent.storage.StakingStorage
    struct StakingStorage {
        // mapping from validator address to validator
        mapping(address => IStaking.Validator) _validatorsMap;
        // mapping from validator owner to validator address
        mapping(address => address) _validatorOwners;
        // list of all validators that are in validators mapping
        address[] _activeValidatorsList;
        // mapping with stakers to validators at epoch (validator -> delegator -> delegation)
        mapping(address => mapping(address => IStaking.ValidatorDelegation)) _validatorDelegations;
        // mapping with validator snapshots per each epoch (validator -> epoch -> snapshot)
        mapping(address => mapping(uint64 => IStaking.ValidatorSnapshot)) _validatorSnapshots;
    }

    /// @custom:storage-location erc7201:Fluent.storage.ConsensusKeysStorage
    struct ConsensusKeysStorage {
        mapping(address => IStaking.ConsensusKeys) consensusKeys;
        // Reverse index peerPubkey => owning validator. Enforces global
        // peerPubkey uniqueness at registration: a duplicate of an existing
        // (e.g. top-k) validator's ed25519 key would otherwise make every
        // future `commitEpochCommittee` unsatisfiable (two equal peerPubkeys
        // break the strictly-ascending committee order while both are counted
        // in `m`) => total chain halt. Append-only field (ERC-7201 safe).
        mapping(bytes32 => address) peerPubkeyOwner;
    }

    /// @custom:storage-location erc7201:Fluent.storage.EpochCommitteeStorage
    struct EpochCommitteeStorage {
        // epoch => committee addresses in canonical Simplex committee order
        // (ed25519 peerPubkey ascending, keyless validators excluded).
        // Empty array == that epoch was never committed (=> unslashable, by design).
        mapping(uint64 => address[]) committee;
        // Highest committed epoch, stored as (epoch + 1). 0 == never committed
        // (genesis-safe idempotent + strictly-monotonic guard).
        uint64 lastCommittedEpochP1;
        // Highest pruned epoch, stored as (epoch + 1). Cursor so a bounded
        // range is pruned each commit even when commits skip epochs.
        uint64 prunedUpToP1;
    }

    /// @custom:storage-location erc7201:Fluent.storage.EquivocationStorage
    struct EquivocationStorage {
        // validator => permanently slashed for a cryptographic equivocation.
        // The flag IS the replay guard: one-and-done tombstone.
        mapping(address => bool) tombstoned;
    }

    /// @custom:storage-location erc7201:Fluent.storage.EpochBeaconStorage
    struct EpochBeaconStorage {
        // epoch => the per-epoch DKG group public key PK_epoch (opaque bytes —
        // the encoded commonware Output's group key). Empty == that epoch had no
        // threshold randomness (the beacon used the deterministic fallback);
        // apps read beaconAssurance() (== key non-empty) to pause.
        mapping(uint64 => bytes) groupPubKey;
        // Highest committed beacon epoch, stored as (epoch + 1). 0 == never
        // committed (genesis-safe idempotent + strictly-monotonic guard); mirror
        // of EpochCommitteeStorage.lastCommittedEpochP1.
        uint64 lastBeaconEpochP1;
    }

    function stakingStorage() internal pure returns (StakingStorage storage $) {
        assembly {
            $.slot := STAKING_STORAGE_LOCATION
        }
    }

    function consensusKeysStorage() internal pure returns (ConsensusKeysStorage storage $) {
        assembly {
            $.slot := CONSENSUS_KEYS_STORAGE_LOCATION
        }
    }

    function epochCommitteeStorage() internal pure returns (EpochCommitteeStorage storage $) {
        assembly {
            $.slot := EPOCH_COMMITTEE_STORAGE_LOCATION
        }
    }

    function equivocationStorage() internal pure returns (EquivocationStorage storage $) {
        assembly {
            $.slot := EQUIVOCATION_STORAGE_LOCATION
        }
    }

    function epochBeaconStorage() internal pure returns (EpochBeaconStorage storage $) {
        assembly {
            $.slot := EPOCH_BEACON_STORAGE_LOCATION
        }
    }

    /// @dev Active-set removal shared by the base jail/disable/remove paths and
    ///      the library's equivocation penalty. Swap-and-pop; no-op if absent
    ///      (only active validators are ever in the list).
    function removeFromActiveList(StakingStorage storage $, address validatorAddress) internal {
        int256 indexOf = -1;
        for (uint256 i = 0; i < $._activeValidatorsList.length; i++) {
            if ($._activeValidatorsList[i] != validatorAddress) continue;
            indexOf = int256(i);
            break;
        }
        if (indexOf >= 0) {
            if ($._activeValidatorsList.length > 1 && uint256(indexOf) != $._activeValidatorsList.length - 1) {
                $._activeValidatorsList[uint256(indexOf)] = $._activeValidatorsList[$._activeValidatorsList.length - 1];
            }
            $._activeValidatorsList.pop();
        }
    }

    /// @dev Materialize (and lazily initialize) the snapshot at `epoch`, copying
    ///      params forward from the validator's last-modified snapshot. Returns a
    ///      storage ref → must stay `internal` (inlined). Mutates the caller's
    ///      `validator` memory (`changedAt`) by reference, exactly as before; the
    ///      caller persists `validator` afterwards. Relocated from `Staking` (no
    ///      immutable / `_currentEpoch` dependency) so both `Staking` lifecycle/slash
    ///      and the `StakingEconomics` delegation/deposit paths call one copy.
    function touchValidatorSnapshot(StakingStorage storage $, IStaking.Validator memory validator, uint64 epoch)
        internal
        returns (IStaking.ValidatorSnapshot storage snapshot)
    {
        snapshot = $._validatorSnapshots[validator.validatorAddress][epoch];
        // if snapshot is already initialized then just return it
        if (snapshot.totalDelegated > 0) {
            return snapshot;
        }
        // find previous snapshot to copy parameters from it
        IStaking.ValidatorSnapshot memory lastModifiedSnapshot =
            $._validatorSnapshots[validator.validatorAddress][validator.changedAt];
        // last modified snapshot might store zero value, for first delegation it might happen and its not critical
        snapshot.totalDelegated = lastModifiedSnapshot.totalDelegated;
        snapshot.commissionRate = lastModifiedSnapshot.commissionRate;
        // we must save last affected epoch for this validator to be able to restore total delegated
        // amount in the future (check condition upper)
        if (epoch > validator.changedAt) {
            validator.changedAt = epoch;
        }
    }

    /// @dev View counterpart of {touchValidatorSnapshot}: returns the materialized
    ///      snapshot in memory without writing storage (used by the at-epoch views).
    function touchValidatorSnapshotImmutable(
        StakingStorage storage $,
        IStaking.Validator memory validator,
        uint64 epoch
    ) internal view returns (IStaking.ValidatorSnapshot memory snapshot) {
        snapshot = $._validatorSnapshots[validator.validatorAddress][epoch];
        // if snapshot is already initialized then just return it
        if (snapshot.totalDelegated > 0) {
            return snapshot;
        }
        // find previous snapshot to copy parameters from it
        IStaking.ValidatorSnapshot memory lastModifiedSnapshot =
            $._validatorSnapshots[validator.validatorAddress][validator.changedAt];
        // last modified snapshot might store zero value, for first delegation it might happen and its not critical
        snapshot.totalDelegated = lastModifiedSnapshot.totalDelegated;
        snapshot.commissionRate = lastModifiedSnapshot.commissionRate;
    }

    /// @dev Most-recent snapshot at or before `epoch` (copy-forward walk). Shared
    ///      so the read path (`Staking` views, removal) and the committee
    ///      selection path (`StakingDpos.commitEpochCommittee`) rank validators
    ///      by exactly the same effective stake — the single source of truth that
    ///      keeps off-chain committee derivation and on-chain verification in lockstep.
    function validatorSnapshotAtOrBefore(StakingStorage storage $, IStaking.Validator memory validator, uint64 epoch)
        internal
        view
        returns (IStaking.ValidatorSnapshot memory)
    {
        uint64 lookupEpoch = epoch < validator.changedAt ? epoch : validator.changedAt;
        while (lookupEpoch > 0) {
            IStaking.ValidatorSnapshot memory snapshot = $._validatorSnapshots[validator.validatorAddress][lookupEpoch];
            if (
                lookupEpoch == validator.changedAt || snapshot.totalDelegated > 0 || snapshot.totalRewards > 0
                    || snapshot.commissionRate > 0 || snapshot.slashesCount > 0
            ) {
                return snapshot;
            }
            unchecked {
                --lookupEpoch;
            }
        }
        return $._validatorSnapshots[validator.validatorAddress][0];
    }

    function totalDelegatedToValidatorAt(IStaking.Validator memory validator, uint64 epoch)
        internal
        view
        returns (uint256)
    {
        IStaking.ValidatorSnapshot memory snapshot = validatorSnapshotAtOrBefore(stakingStorage(), validator, epoch);
        return uint256(snapshot.totalDelegated) * BALANCE_COMPACT_PRECISION;
    }

    /// @dev Stake-weighted top-k active set ranked by each validator's delegated
    ///      stake AS OF `epoch` (not necessarily the current epoch). Selecting at
    ///      a future `epoch` is what enables committing the committee one epoch
    ///      ahead (see `StakingDpos.commitEpochCommittee`). `cfg` is passed in so
    ///      both `Staking` (immutable) and `StakingDpos` (DELEGATECALL, no
    ///      reachable immutable) call the identical implementation.
    function getValidatorsAt(IChainConfig cfg, uint64 epoch) internal view returns (address[] memory) {
        StakingStorage storage $ = stakingStorage();
        uint256 n = $._activeValidatorsList.length;
        address[] memory orderedValidators = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            orderedValidators[i] = $._activeValidatorsList[i];
        }
        // we need to select k top validators out of n
        uint256 k = cfg.getActiveValidatorsLength();
        if (k > n) {
            k = n;
        }
        for (uint256 i = 0; i < k; i++) {
            uint256 nextValidator = i;
            IStaking.Validator memory currentMax = $._validatorsMap[orderedValidators[nextValidator]];
            for (uint256 j = i + 1; j < n; j++) {
                IStaking.Validator memory current = $._validatorsMap[orderedValidators[j]];
                if (totalDelegatedToValidatorAt(currentMax, epoch) < totalDelegatedToValidatorAt(current, epoch)) {
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
}
