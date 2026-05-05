// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/// @title Staking governance interface
/// @notice Exposes voting supply and validator voting power to governance integrations.
interface IGovernance {
    /// @notice Returns total voting supply available to governance.
    function getVotingSupply() external view returns (uint256);

    /// @notice Returns voting power for `validator`.
    function getVotingPower(address validator) external view returns (uint256);
}
