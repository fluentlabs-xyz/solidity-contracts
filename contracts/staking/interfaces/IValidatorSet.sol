// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/**
 * @title IValidatorSet interface
 * @author Fluent Labs
 * @notice Minimal interface used by system components that only need validator ordering.
 */
interface IValidatorSet {
    /**
     * @notice Returns the current active validator set ordered by delegated amount.
     */
    function getValidators() external view returns (address[] memory);
}
