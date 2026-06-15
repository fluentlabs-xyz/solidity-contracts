// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StakingContext} from "./StakingContext.sol";
import {StakingDpos} from "./StakingDpos.sol";
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
    event LivenessSlashDispatched(
        uint64 indexed epoch,
        uint32 indexed signerIdx,
        address indexed validator
    );

    // ERC-7201 storage namespace:
    // keccak256(abi.encode(uint256(keccak256("Fluent.storage.LivenessSlashingStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LIVENESS_SLASHING_STORAGE_LOCATION =
        0xcdf1e9106d462d95f24a4f73d10fa2eb0e161882b0a384920def44fb49e57500;

    /// @custom:storage-location erc7201:Fluent.storage.LivenessSlashingStorage
    struct LivenessSlashingStorage {
        /// Per-(epoch, signer_idx) consecutive miss counter.
        /// Reset to 0 on (a) participation, (b) slash emission.
        mapping(uint64 epoch => mapping(uint32 signerIdx => uint32 missCount)) _missCounter;
        /// Last EVM `block.number` processed — idempotency guard.
        /// Lives in EVM state so reorg-rollback re-arms it automatically.
        uint64 _lastProcessedBlock;
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
    function processBitmap(
        uint64 epoch,
        uint64 blockNumber,
        uint8 committeeSize,
        bytes calldata signersBitmap
    ) external onlySystemCall {
        if (committeeSize == 0) return; // cold-start / no-prev-cert no-op
        LivenessSlashingStorage storage $ = _getLivenessSlashingStorage();
        if (blockNumber <= $._lastProcessedBlock) return;
        $._lastProcessedBlock = blockNumber;

        // The consensus `verify` predicate is deliberately structural-only over a
        // non-deterministic cert bitmap, so a Byzantine proposer freely chooses
        // `epoch` and `committeeSize` in the header. `epoch` and `committeeSize`
        // ARE deterministic over agreed state, so validate them here (the single
        // trust boundary) — a missing check let a single proposer accumulate
        // `missCounter[stale_epoch][victim]` (never reset by honest blocks, which
        // only write the current epoch) to a slash of an honest validator, or
        // index a phantom signer past the committed committee (audit P2-5).
        // Skip-not-revert: an honest cert always passes; rejecting malformed input
        // by skipping this block's accounting avoids coupling to the executor's
        // tolerated-revert set and never wedges the chain.
        uint64 currentEpoch = StakingDpos._epochAt(_chainConfigContract, blockNumber);
        bool epochInWindow = epoch == currentEpoch || (currentEpoch > 0 && epoch == currentEpoch - 1);
        if (!epochInWindow) return;
        // Ties the proposer-supplied size to the committed committee, eliminating
        // phantom indices (`resolveSigner` past the real length) outright. Length-
        // only getter (single SLOAD) — not getEpochCommittee (copies the array).
        if (_stakingContract.getEpochCommitteeLength(epoch) != committeeSize) return;

        uint256 expectedLen = (uint256(committeeSize) + 7) / 8;
        require(signersBitmap.length == expectedLen, InvalidBitmapLength());

        mapping(uint32 => uint32) storage missCounter = $._missCounter[epoch];
        // Single SLOAD via the config getter (sentinel-defaults to 50); read
        // once, not per committee member.
        uint32 missThreshold = _chainConfigContract.getMissThreshold();

        for (uint8 i = 0; i < committeeSize; i++) {
            bool present = (uint8(signersBitmap[i >> 3]) >> (i & 7)) & 1 == 1;
            if (present) {
                if (missCounter[i] != 0) missCounter[i] = 0;
            } else {
                uint32 c = missCounter[i] + 1;
                if (c >= missThreshold) {
                    missCounter[i] = 0;
                    address victim = _stakingContract.resolveSigner(epoch, uint32(i));
                    emit LivenessSlashDispatched(epoch, uint32(i), victim);
                    _stakingContract.slash(victim);
                } else {
                    missCounter[i] = c;
                }
            }
        }
    }

    /// @notice View: current miss count for `(epoch, signerIdx)`. Used by
    ///         the state-polling monitor in addition to the
    ///         `LivenessSlashDispatched` event.
    function missCount(uint64 epoch, uint32 signerIdx) external view returns (uint32) {
        return _getLivenessSlashingStorage()._missCounter[epoch][signerIdx];
    }

    /// @notice View: the most recent EVM `block.number` for which
    ///         `processBitmap` was successfully invoked. Useful for ops to
    ///         verify the executor pipeline is firing.
    function lastProcessedBlock() external view returns (uint64) {
        return _getLivenessSlashingStorage()._lastProcessedBlock;
    }
}
