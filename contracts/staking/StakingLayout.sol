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
        // Validators currently in a LIVENESS jail (removed from _activeValidatorsList), pending
        // automatic re-admit once currentEpoch >= their jailedBefore. Append-only (struct-tail
        // append after a mapping is ERC-7201 safe). NOT used for equivocation — tombstoned
        // validators are permanent and never enter this set.
        address[] _jailedValidators;
        // --- Selection view (committee-eligibility) — decoupled from the LIVE list. ---
        // The SELECTION view (getValidatorsAt) must be a PURE function of the selection
        // epoch: a status transition at epoch T takes selection-effect only at T+1, so a
        // committee minted from EffBal(T) is deterministic no matter WHEN in epoch T it is
        // derived (mirrors the 2-epoch stake-snapshot freeze). The LIVE `_activeValidatorsList`
        // and its consumers (halt-guard, BLEND settlement, getRegistryWithKeys) are UNTOUCHED
        // — they still mutate immediately. Because an EXIT (jail/disable/remove) must stay
        // selection-visible through its final epoch T while the live list drops it at T, the
        // selection view iterates its OWN append-only roster instead of the live list.
        //
        // Roster of every validator that has ever been Active (pushed on Active-creation via
        // seedSelectionMembership, or on a Pending registrant's first activation via
        // ensureRostered; swap-pop on removeValidator only). Never-activated Pending registrants
        // are deliberately excluded — they are selection-invisible at every queryable epoch, so
        // rostering them would only bloat the O(rosterLen) getValidatorsAt scan. Iterated by
        // getValidatorsAt; each entry further gated by its per-validator visibility stamp.
        address[] _selectionRoster;
        // Per-validator selection visibility stamp. `visible` applies from `effectiveFrom`;
        // for epochs < effectiveFrom, `prevVisible` applies. See setSelectionVisible.
        mapping(address => SelectionMembership) _selectionMembership;
    }

    /// @notice Two-tier selection-visibility stamp making getValidatorsAt(E) a pure
    ///         function of E. `visibleAt(E) = E >= effectiveFrom ? visible : prevVisible`.
    struct SelectionMembership {
        bool visible;
        bool prevVisible;
        uint64 effectiveFrom;
        // Whether `v` is present in `_selectionRoster`. Set once on the FIRST Active transition
        // (genesis/gov Active-creation, or the first activateValidator of a Pending registrant);
        // guards ensureRostered against a double-push on disable→re-enable / jail→readmit. Cleared
        // by removeFromSelectionRoster so a re-register+re-activate re-pushes. Appended field —
        // packs into the existing slot (bool+bool+uint64+bool = 11 bytes ≤ 32), ERC-7201 safe.
        bool rostered;
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
        // epoch => whether a DKG qualification was recorded for that epoch's
        // committee. false == not recorded yet (=> a CHANGE-epoch boundary re-commits
        // the incumbent committee instead of opening a shareless candidate); true ==
        // qualified (=> commit the candidate). PRESENCE-ONLY (no PK / commitment
        // stored): the agreed-dealing-set design (AMENDMENT 5) makes an honest key
        // divergence impossible by construction, so no on-chain PK witness is needed
        // — the marker only gates the deferred commit. Set ONCE by the permissionless
        // `recordDkgQual`; a repeat is a no-op. Append-only field after a mapping tail
        // — ERC-7201 safe (new namespaced slots, none reused).
        mapping(uint64 => bool) dkgQual;
    }

    /// @custom:storage-location erc7201:Fluent.storage.EquivocationStorage
    struct EquivocationStorage {
        // validator => permanently slashed for a cryptographic equivocation.
        // The flag IS the replay guard: one-and-done tombstone.
        mapping(address => bool) tombstoned;
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

    /// @dev Swap-and-pop `value` out of an order-agnostic address membership set; no-op if absent.
    ///      Single source for the active-set and jailed-set removals (F12 dedup).
    function swapPop(address[] storage arr, address value) internal {
        uint256 len = arr.length;
        for (uint256 i = 0; i < len; i++) {
            if (arr[i] != value) continue;
            if (i != len - 1) {
                arr[i] = arr[len - 1];
            }
            arr.pop();
            return;
        }
    }

    /// @dev Active-set removal shared by the base jail/disable/remove paths and
    ///      the library's equivocation penalty. Swap-and-pop; no-op if absent
    ///      (only active validators are ever in the list).
    function removeFromActiveList(StakingStorage storage $, address validatorAddress) internal {
        swapPop($._activeValidatorsList, validatorAddress);
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

    /// @dev Materialize snapshot[epoch] for a PAST/CURRENT-epoch writer (settlement credit at
    ///      E=current-2, liveness slash at `current`). Copies base params from the most-recent
    ///      AT-OR-BEFORE snapshot instead of from `changedAt` — the latter is in the FUTURE whenever a
    ///      pending delegate (e+2) / undelegate (e+1) already advanced the frontier, and copying it
    ///      forward materializes a too-small/too-large `totalDelegated` that the per-delegator claim then
    ///      reads as its split denominator (the F1 BLEND drain / dust). For a frontier-advancing target
    ///      (epoch >= changedAt) validatorSnapshotAtOrBefore returns snapshot[changedAt] verbatim, so a
    ///      slash at `current` in the normal (no-pending-op) case is byte-identical to touchValidatorSnapshot.
    ///      Distinct from touchValidatorSnapshot because the delegate/undelegate/lifecycle writers TARGET a
    ///      future epoch (e+1/e+2) and legitimately rely on the copy-forward-from-changedAt to accumulate
    ///      not-yet-effective stake — the at-or-before base must NOT bleed into those callers.
    function touchSnapshotAtOrBefore(
        StakingLayout.StakingStorage storage $,
        IStaking.Validator memory validator,
        uint64 epoch
    ) internal returns (IStaking.ValidatorSnapshot storage snapshot) {
        snapshot = $._validatorSnapshots[validator.validatorAddress][epoch];
        if (snapshot.totalDelegated > 0) {
            return snapshot;
        }
        IStaking.ValidatorSnapshot memory base = validatorSnapshotAtOrBefore($, validator, epoch);
        snapshot.totalDelegated = base.totalDelegated;
        snapshot.commissionRate = base.commissionRate;
        // Preserve the frontier-advance so a slash at `current > changedAt` remains behavior-identical
        // to touchValidatorSnapshot (a backward credit at E < changedAt never triggers this).
        if (epoch > validator.changedAt) {
            validator.changedAt = epoch;
        }
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
                lookupEpoch == validator.changedAt || snapshot.totalDelegated > 0 || snapshot.totalBlendRewards > 0
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

    /// @dev Selection visibility of `v` AS OF selection-epoch `E`: `visible` from
    ///      `effectiveFrom`, else `prevVisible`. Pure function of E — the whole point.
    function selectionVisibleAt(StakingStorage storage $, address v, uint64 epoch) internal view returns (bool) {
        SelectionMembership storage m = $._selectionMembership[v];
        return epoch >= m.effectiveFrom ? m.visible : m.prevVisible;
    }

    /// @dev Stamp a status transition at `currentEpoch` so it takes SELECTION effect at
    ///      `currentEpoch + 1` (uniform for jail/equivocation/disable/activate/reinstate).
    ///      `getValidatorsAt(E)` for E <= currentEpoch keeps reading `prevVisible`, so a
    ///      mid-epoch transition never changes an in-flight selection. Multiple transitions
    ///      in one epoch: last-write-wins, `prevVisible` preserved (only the first bumps it).
    function setSelectionVisible(StakingStorage storage $, address v, bool nowVisible, uint64 currentEpoch) internal {
        SelectionMembership storage m = $._selectionMembership[v];
        uint64 eff = currentEpoch + 1;
        if (m.effectiveFrom == eff) {
            // already transitioned this epoch — keep prevVisible, overwrite the pending value
            m.visible = nowVisible;
        } else {
            // effectiveFrom <= currentEpoch here, so `visible` is the value in force at
            // currentEpoch → it becomes the new `prevVisible` for epochs < eff.
            m.prevVisible = m.visible;
            m.visible = nowVisible;
            m.effectiveFrom = eff;
        }
    }

    /// @dev Seed the selection stamp at validator CREATION. Genesis (`sinceEpoch == 0`) is
    ///      visible from epoch 0; a runtime creation (`sinceEpoch == nextEpoch`) is visible
    ///      from that epoch — mirroring the stake-snapshot `sinceEpoch` treatment. NOT a
    ///      `+1` transition: creation establishes the initial condition, not a change.
    ///
    ///      The roster PUSH is decoupled from the stamp: a never-activated Pending validator is
    ///      selection-invisible at EVERY queryable epoch, so pushing it onto `_selectionRoster`
    ///      only bloats the O(rosterLen) getValidatorsAt scan (permissionless registerValidator
    ///      DoS). Push ONLY on Active-at-creation (genesis / gov addValidator); a Pending
    ///      registrant gets its stamp seeded but stays out of the roster until ensureRostered on
    ///      its first activation. `rostered` mirrors `visibleInit` so the Active-creation entry
    ///      is not double-pushed later.
    function seedSelectionMembership(StakingStorage storage $, address v, bool visibleInit, uint64 sinceEpoch)
        internal
    {
        if (visibleInit) {
            $._selectionRoster.push(v);
        }
        $._selectionMembership[v] = SelectionMembership({
            visible: visibleInit, prevVisible: false, effectiveFrom: sinceEpoch, rostered: visibleInit
        });
    }

    /// @dev Ensure `v` is present in `_selectionRoster`, pushing at most once. Called on the FIRST
    ///      Active transition of a Pending registrant (activateValidator). A no-op for a validator
    ///      already rostered (genesis/gov-Active, or a disabled/jailed validator being re-enabled —
    ///      those keep roster membership), so it never introduces a duplicate roster entry (a dup
    ///      would break the strictly-ascending committee commit order → halt).
    function ensureRostered(StakingStorage storage $, address v) internal {
        SelectionMembership storage m = $._selectionMembership[v];
        if (!m.rostered) {
            $._selectionRoster.push(v);
            m.rostered = true;
        }
    }

    /// @dev Drop a validator from the selection roster + stamp (only on removeValidator). Deleting
    ///      the stamp clears `rostered`, so a re-register+re-activate correctly re-pushes.
    function removeFromSelectionRoster(StakingStorage storage $, address v) internal {
        swapPop($._selectionRoster, v);
        delete $._selectionMembership[v];
    }

    /// @dev Stake-weighted top-k SELECTION set ranked by each validator's delegated
    ///      stake AS OF `epoch` (not necessarily the current epoch). Iterates the
    ///      append-only `_selectionRoster` (NOT the live active list) filtered by the
    ///      per-validator visibility stamp, so the result is a pure function of `epoch`
    ///      — committing the committee one epoch ahead is deterministic no matter when
    ///      it is derived (see `StakingDpos.commitEpochCommittee`). `cfg` is passed in so
    ///      both `Staking` (immutable) and `StakingDpos` (DELEGATECALL, no
    ///      reachable immutable) call the identical implementation.
    function getValidatorsAt(IChainConfig cfg, uint64 epoch) internal view returns (address[] memory) {
        StakingStorage storage $ = stakingStorage();
        uint256 rosterLen = $._selectionRoster.length;
        // Collect the selection-visible-at-`epoch` subset of the roster.
        address[] memory candidates = new address[](rosterLen);
        uint256 n = 0;
        for (uint256 i = 0; i < rosterLen; i++) {
            address v = $._selectionRoster[i];
            if (selectionVisibleAt($, v, epoch)) {
                candidates[n] = v;
                n++;
            }
        }
        assembly {
            mstore(candidates, n)
        }
        return _topKByStakeAt(cfg, candidates, epoch);
    }

    /// @dev The LIVE current top-k over `_activeValidatorsList` (immediate membership),
    ///      ranked by stake as of `epoch`. Distinct from `getValidatorsAt`: this is what
    ///      the non-selection consumers (`getValidators`, `isValidatorActive`) want — the
    ///      set of validators active RIGHT NOW, NOT the epoch-frozen selection view. Never
    ///      used for committee derivation (that must be the deterministic `getValidatorsAt`).
    function getLiveValidators(IChainConfig cfg, uint64 epoch) internal view returns (address[] memory) {
        StakingStorage storage $ = stakingStorage();
        uint256 len = $._activeValidatorsList.length;
        address[] memory candidates = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            candidates[i] = $._activeValidatorsList[i];
        }
        return _topKByStakeAt(cfg, candidates, epoch);
    }

    /// @dev Shared stake-weighted top-k selection sort over an arbitrary candidate set,
    ///      ranked by `totalDelegatedToValidatorAt(epoch)`. Mutates + trims `candidates`
    ///      in place to the first `k` (capped by `getActiveValidatorsLength`).
    function _topKByStakeAt(IChainConfig cfg, address[] memory candidates, uint64 epoch)
        private
        view
        returns (address[] memory)
    {
        StakingStorage storage $ = stakingStorage();
        uint256 n = candidates.length;
        uint256 k = cfg.getActiveValidatorsLength();
        if (k > n) {
            k = n;
        }
        for (uint256 i = 0; i < k; i++) {
            uint256 nextValidator = i;
            IStaking.Validator memory currentMax = $._validatorsMap[candidates[nextValidator]];
            for (uint256 j = i + 1; j < n; j++) {
                IStaking.Validator memory current = $._validatorsMap[candidates[j]];
                if (totalDelegatedToValidatorAt(currentMax, epoch) < totalDelegatedToValidatorAt(current, epoch)) {
                    nextValidator = j;
                    currentMax = current;
                }
            }
            address backup = candidates[i];
            candidates[i] = candidates[nextValidator];
            candidates[nextValidator] = backup;
        }
        // cut to first k without copying
        assembly {
            mstore(candidates, k)
        }
        return candidates;
    }
}
