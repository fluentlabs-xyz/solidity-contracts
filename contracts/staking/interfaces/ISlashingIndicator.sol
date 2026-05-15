// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/**
 * @title Slashing Indicator interface
 * @author Fluent Labs
 * @notice Entry point for reporting validator faults to staking.
 */
interface ISlashingIndicator {
    /**
     * @dev Records a slash event for `validator`.
     * @param validator The address of the validator to slash.
     *
     * emits:
     * - ValidatorSlashed(validator, slashes, epoch)
     */
    function slash(address validator) external;
}
