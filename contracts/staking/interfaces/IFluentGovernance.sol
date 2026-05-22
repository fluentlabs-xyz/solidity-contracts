// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/**
 * @title IFluentGovernance
 * @author Fluent Labs
 * @notice Exposes voting supply and validator-owner voting power to governance integrations.
 * @dev Voting power is derived from the validator each owner controls, measured at the requested
 *      block number. Governance Governor instances call these helpers to compute quorum and vote
 *      weights.
 */
interface IFluentGovernance {
    /**
     * @notice Caller is not the active validator owner required by a governance action.
     */
    error OnlyValidatorOwner();

    /**
     * @notice Returns the total voting supply available to governance at the current block.
     * @return supply Voting supply (sum of all active validators' weights).
     */
    function getVotingSupply() external view returns (uint256 supply);

    /**
     * @notice Returns the voting power held by the validator owned by `validatorOwner`.
     * @dev Measured against the current block; off-chain consumers reconstruct historical
     *      voting power directly through the governor's checkpointed clock.
     * @param validatorOwner Owner address whose validator's voting power is reported.
     * @return power Voting power for the owner's validator at the current block.
     */
    function getVotingPower(address validatorOwner) external view returns (uint256 power);
}
