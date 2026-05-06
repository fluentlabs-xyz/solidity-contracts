// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/// @title Active validator set interface
/// @notice Minimal interface used by system components that only need validator ordering and reward deposit hooks.
interface IValidatorSet {
    /// @notice Returns the current active validator set ordered by delegated amount.
    function getValidators() external view returns (address[] memory);

    /// @notice Deposits staking-token rewards for `validator`; in production called by the block coinbase path.
    function deposit(address validator, uint256 amount) external;
}
