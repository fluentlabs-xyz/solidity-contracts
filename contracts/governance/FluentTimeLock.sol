// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title FluentTimeLock
 * @author Fluent Labs
 * @notice Thin wrapper over OZ TimelockController for Fluent governance.
 * @dev Deployed as plain contract (not upgradeable). Admin is set to address(0)
 *      making the timelock self-administered — only scheduled operations can
 *      change the timelock's own configuration (delay, roles).
 */
contract FluentTimeLock is TimelockController {
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors
    ) TimelockController(minDelay, proposers, executors, address(0)) {}
}
