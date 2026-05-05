// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/// @title Slashing indicator interface
/// @notice Entry point for reporting validator faults to staking.
interface ISlashingIndicator {
    /// @notice Records a slash for `validator`.
    function slash(address validator) external;
}
