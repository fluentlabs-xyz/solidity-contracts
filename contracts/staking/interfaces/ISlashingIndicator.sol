// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/**
 * @title ISlashingIndicator
 * @author Fluent Labs
 * @notice Coinbase-only adapter used by the consensus layer to report validator faults to {IStaking}.
 * @dev The implementation forwards `slash` calls to {IStaking-slash} and is the only contract
 *      authorized to do so on behalf of the coinbase address.
 */
interface ISlashingIndicator {
    /**
     * @notice Records a slash event for `validator`.
     * @dev Triggers {IStakingEvents-ValidatorSlashed} on the staking contract once accounting
     *      is updated. Callable only by the coinbase address.
     * @param validator Validator to slash.
     */
    function slash(address validator) external;
}
