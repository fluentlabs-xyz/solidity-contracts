// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/// @title BLEND stipend reserve interface
/// @notice The BLEND reserve `Staking.settleEpochStipend` draws the per-epoch stipend from.
interface IBlendReserve {
    /// @notice Disburse up to `amount` BLEND to `to`; returns the amount actually sent =
    ///         min(amount, balance) (balance-clamp → empties to 0 gracefully). Best-effort.
    function disburse(address to, uint256 amount) external returns (uint256 sent);

    /// @notice Current BLEND balance held by the reserve.
    function reserveBalance() external view returns (uint256);
}
