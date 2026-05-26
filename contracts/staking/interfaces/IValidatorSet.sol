// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/**
 * @title IValidatorSet
 * @author Fluent Labs
 * @notice Minimal validator-set surface used by system components that only need active-set
 *         ordering and reward deposit hooks.
 * @dev Extracted from {IStaking} so consensus and reward-distribution paths can depend on the
 *      thinnest possible interface.
 */
interface IValidatorSet {
    /**
     * @notice Returns the current active validator set, ordered by delegated amount.
     * @return validators Active validator addresses sorted from highest to lowest stake.
     */
    function getValidators() external view returns (address[] memory validators);

    /**
     * @notice Deposits staking-token rewards earmarked for `validator`.
     * @dev In production this is called by the block coinbase path; integration tests invoke it
     *      directly to simulate validator rewards.
     * @param validator Validator address the deposit is credited to.
     * @param amount Reward amount, denominated in staking tokens.
     */
    function deposit(address validator, uint256 amount) external;
}
