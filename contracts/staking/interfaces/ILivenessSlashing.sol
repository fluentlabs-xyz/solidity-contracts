// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/// @title Liveness participation source interface
/// @notice The canonical windowed-participation counters, consumed by `Staking.settleEpochStipend`
///         for the BLEND-stipend live-passer gate.
interface ILivenessSlashing {
    /// @notice Certs `signerIdx` signed and total certs processed in `epoch`'s window.
    function participation(uint64 epoch, uint32 signerIdx) external view returns (uint32 seen, uint32 certs);

    /// @notice The highest epoch whose participation window has been finalized.
    function lastFinalizedEpoch() external view returns (uint64);

    /// @notice The participation-window finalization cursor as (epoch + 1). 0 == none finalized
    ///         (unambiguous, unlike {lastFinalizedEpoch} which returns 0 both for "none" and "only
    ///         epoch 0"). Consumed by `Staking.settleEpochStipend` to never settle past the finalized
    ///         frontier.
    function lastFinalizedEpochP1() external view returns (uint64);
}
