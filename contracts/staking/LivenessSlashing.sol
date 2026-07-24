// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StakingContext} from "./StakingContext.sol";
import {StakingDpos} from "./StakingDpos.sol";
import {ParticipationMath} from "./ParticipationMath.sol";
import {IStaking} from "./interfaces/IStaking.sol";
import {ISystemReward} from "./interfaces/ISystemReward.sol";
import {IStakingPool} from "./interfaces/IStakingPool.sol";
import {IFluentGovernance} from "./interfaces/IFluentGovernance.sol";
import {IChainConfig} from "./interfaces/IChainConfig.sol";

/// @title LivenessSlashing
/// @author Fluent Labs
/// @notice System-call-driven on-chain miss counter. Called once per block
///         from `FluentBlockExecutor::apply_pre_execution_changes` with the
///         signer bitmap of the previous finalized cert. At threshold,
///         calls `Staking.slash(victim)`.
contract LivenessSlashing is StakingContext {
    /// @notice Emitted when sustained-miss threshold is reached and a
    ///         slash is dispatched to `Staking.slash`.
    event LivenessSlashDispatched(uint64 indexed epoch, uint32 indexed signerIdx, address indexed validator);

    /// @notice Emitted when a committee member falls below the participation floor over a
    ///         finalized window and a participation-floor jail is dispatched to `Staking.slash`.
    event LivenessParticipationJail(
        uint64 indexed epoch, uint32 indexed signerIdx, address indexed validator, uint32 seen, uint32 certs
    );

    // ERC-7201 storage namespace:
    // keccak256(abi.encode(uint256(keccak256("Fluent.storage.LivenessSlashingStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LIVENESS_SLASHING_STORAGE_LOCATION =
        0xcdf1e9106d462d95f24a4f73d10fa2eb0e161882b0a384920def44fb49e57500;

    /// @custom:storage-location erc7201:Fluent.storage.LivenessSlashingStorage
    struct LivenessSlashingStorage {
        /// Last EVM `block.number` processed — idempotency guard.
        /// Lives in EVM state so reorg-rollback re-arms it automatically.
        uint64 _lastProcessedBlock;
        // --- appended (windowed/relative participation) ---
        /// Per-(epoch, signer_idx) count of certs the member signed within the epoch's window.
        mapping(uint64 epoch => mapping(uint32 signerIdx => uint32 seen)) _seenCount;
        /// Per-epoch count of certs processed within the window.
        mapping(uint64 epoch => uint32 certs) _certCount;
        /// (epoch + 1) participation-window finalization cursor. 0 == none finalized.
        uint64 _lastFinalizedEpochP1;
    }

    function _getLivenessSlashingStorage() private pure returns (LivenessSlashingStorage storage $) {
        assembly {
            $.slot := LIVENESS_SLASHING_STORAGE_LOCATION
        }
    }

    constructor(
        IStaking stakingContract,
        ISystemReward systemRewardContract,
        IStakingPool stakingPoolContract,
        IFluentGovernance governanceContract,
        IChainConfig chainConfigContract,
        IERC20 stakingToken
    )
        StakingContext(
            stakingContract,
            systemRewardContract,
            stakingPoolContract,
            governanceContract,
            chainConfigContract,
            stakingToken
        )
    {}

    function initialize(address initialOwner) external initializer {
        __StakingContext_init(initialOwner);
    }

    /// @notice Thrown when the bitmap length does not match `ceil(committeeSize/8)`.
    error InvalidBitmapLength();

    /// @notice Process one finalized cert's participation bitmap.
    /// @param epoch         Epoch of the bitmap (committee lookup + counter key).
    /// @param blockNumber   EVM `block.number` of the current block (idempotency key).
    /// @param committeeSize Number of validators in `epoch`'s committee.
    /// @param signersBitmap Canonical LSB-first byte format: bit `i` of byte `i/8`
    ///                      = signer `i` present.
    function processBitmap(uint64 epoch, uint64 blockNumber, uint8 committeeSize, bytes calldata signersBitmap)
        external
        onlySystemCall
    {
        if (committeeSize == 0) return; // cold-start / no-prev-cert no-op
        LivenessSlashingStorage storage $ = _getLivenessSlashingStorage();
        if (blockNumber <= $._lastProcessedBlock) return; // idempotency
        $._lastProcessedBlock = blockNumber;

        // Derive the epoch from the block, NEVER trust the proposer-supplied `epoch` tag: the
        // consensus `verify` predicate is structural-only over a non-deterministic cert bitmap,
        // so a Byzantine proposer freely chooses `epoch`/`committeeSize` in the header, but the
        // block number is deterministic over agreed state (audit P2-5 / F9).
        uint64 currentEpoch = StakingDpos._epochAt(_chainConfigContract, blockNumber);

        // Auto-reinstate sweep + window finalize run BEFORE the in-window validation early-returns
        // so they fire on every fresh block regardless of this block's bitmap tag.
        _stakingContract.readmitExpiredJails(currentEpoch);
        _maybeFinalizeParticipation($, currentEpoch);

        // Accumulate into the tag epoch, validated in-window and tied to the committed committee.
        // Skip-not-revert: an honest cert always passes; rejecting malformed input by skipping
        // this block's accounting never wedges the chain.
        bool epochInWindow = epoch == currentEpoch || (currentEpoch > 0 && epoch == currentEpoch - 1);
        if (!epochInWindow) return;
        // Ties the proposer-supplied size to the committed committee, eliminating phantom indices.
        if (_stakingContract.getEpochCommitteeLength(epoch) != committeeSize) return;

        uint256 expectedLen = (uint256(committeeSize) + 7) / 8;
        require(signersBitmap.length == expectedLen, InvalidBitmapLength());

        $._certCount[epoch] += 1;
        mapping(uint32 => uint32) storage seen = $._seenCount[epoch];
        for (uint8 i = 0; i < committeeSize; i++) {
            if ((uint8(signersBitmap[i >> 3]) >> (i & 7)) & 1 == 1) seen[i] += 1;
        }
    }

    /// @notice Finalize every window that is provably CLOSED. The accept-window for a cert is
    ///         {currentEpoch, currentEpoch-1}, so a cert tagged E can still arrive at block-epoch
    ///         E+1; epoch E is complete only once block-epoch >= E+2. Hence the finalize target is
    ///         `currentEpoch - 2` (F9 finality lag); a bounded catch-up loop covers skipped epochs.
    function _maybeFinalizeParticipation(LivenessSlashingStorage storage $, uint64 currentEpoch) internal {
        if (currentEpoch < 2) return;
        uint64 to = currentEpoch - 2; // last fully-closed target
        for (uint64 target = $._lastFinalizedEpochP1; target <= to; target++) {
            _finalizeWindow($, target);
            $._lastFinalizedEpochP1 = target + 1;
        }
    }

    function _finalizeWindow(LivenessSlashingStorage storage $, uint64 target) internal {
        uint32 certs = $._certCount[target];
        if (certs == 0) return; // empty window → nothing to judge
        // Governance kill switch: when disabled, the window is still finalized (the cursor has
        // already advanced in _maybeFinalizeParticipation) and its seen/certs counters stay readable
        // via participation(), but no member is judged/jailed. A window finalized while disabled is
        // therefore PERMANENTLY unjudged — re-enabling never retro-scans it (the cursor moved past).
        if (_chainConfigContract.getParticipationJailDisabled()) return;
        uint32 floorBps = _chainConfigContract.getParticipationFloorBps();
        uint256 n = _stakingContract.getEpochCommitteeLength(target);

        // First pass: count below-floor members for the single-window correlation guard.
        mapping(uint32 => uint32) storage seen = $._seenCount[target];
        uint256 belowFloor = 0;
        for (uint32 i = 0; i < n; i++) {
            if (ParticipationMath.belowFloor(seen[i], certs, floorBps)) belowFloor++;
        }
        // Correlation guard: > f simultaneous failures ⇒ a network/consensus event, not individual
        // downtime (Simplex stop-at-quorum makes bitmap-absence != offline). Shared f/belowFloor with the
        // BLEND stipend gate (StakingRewards) so the two paths can never split-brain on what a correlated
        // window means (F11 single source).
        if (belowFloor > ParticipationMath.faultTolerance(n)) return; // skip jailing this window

        for (uint32 i = 0; i < n; i++) {
            if (ParticipationMath.belowFloor(seen[i], certs, floorBps)) {
                address victim = _stakingContract.resolveSigner(target, i);
                emit LivenessParticipationJail(target, i, victim, seen[i], certs);
                // Skip-not-revert: a single bad victim (e.g. tombstoned/removed between commit and
                // finalize → ValidatorNotFound) must not revert processBitmap and roll back the
                // sweep + accumulation of this whole block.
                try _stakingContract.slash(victim) {} catch {}
            }
        }
    }

    /// @notice View: participation counters for `(epoch, signerIdx)` — certs the member signed and
    ///         the total certs processed in the window. Consumed by `Staking.settleEpochStipend`
    ///         (BLEND-stipend passer gate) and by ops monitors.
    function participation(uint64 epoch, uint32 signerIdx) external view returns (uint32 seen, uint32 certs) {
        LivenessSlashingStorage storage $ = _getLivenessSlashingStorage();
        return ($._seenCount[epoch][signerIdx], $._certCount[epoch]);
    }

    /// @notice View: the highest epoch whose participation window has been finalized. Returns 0
    ///         both when nothing has finalized and when only epoch 0 has; callers that must
    ///         distinguish should read the raw `_lastFinalizedEpochP1` semantics via events.
    function lastFinalizedEpoch() external view returns (uint64) {
        uint64 p1 = _getLivenessSlashingStorage()._lastFinalizedEpochP1;
        return p1 == 0 ? 0 : p1 - 1;
    }

    /// @notice View: the participation-window finalization cursor as (epoch + 1). 0 == none finalized
    ///         (disambiguates "nothing finalized" from "only epoch 0 finalized"). Consumed by
    ///         `Staking.settleEpochStipend` to gate settlement to the finalized frontier.
    function lastFinalizedEpochP1() external view returns (uint64) {
        return _getLivenessSlashingStorage()._lastFinalizedEpochP1;
    }

    /// @notice View: the most recent EVM `block.number` for which
    ///         `processBitmap` was successfully invoked. Useful for ops to
    ///         verify the executor pipeline is firing.
    function lastProcessedBlock() external view returns (uint64) {
        return _getLivenessSlashingStorage()._lastProcessedBlock;
    }
}
