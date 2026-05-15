// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/**
 * @title Fluent Governance interface
 * @author Fluent Labs
 * @notice Exposes voting supply and validator voting power to governance integrations.
 */
interface IFluentGovernance {
    /**
     * @dev The `account` is not a validator owner.
     * @dev selector: TODO
     */
    error OnlyValidatorOwner();

    /**
     * @dev Returns total voting supply available to governance.
     */
    function getVotingSupply() external view returns (uint256);

    /**
     * @dev Returns voting power for `validator`.
     */
    function getVotingPower(address validator) external view returns (uint256);
}
