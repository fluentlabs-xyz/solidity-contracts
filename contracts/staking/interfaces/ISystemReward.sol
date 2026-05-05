// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/// @title System reward interface
/// @notice Receives system fees and distributes them across governance-configured accounts.
interface ISystemReward {
    /// @notice Replaces fee distribution recipients and shares. Total share must equal 10000.
    function updateDistributionShare(address[] calldata accounts, uint16[] calldata shares) external;

    /// @notice Returns undistributed system fee balance tracked by the contract.
    function getSystemFee() external view returns (uint256);

    /// @notice Distributes currently accumulated system fees when above the minimum threshold.
    function claimSystemFee() external;
}
