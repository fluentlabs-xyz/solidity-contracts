// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title IBlacklist
 * @author Fluent Labs
 * @notice Registry consulted by {FluentBridge} (and optionally other contracts) to block outbound
 *         bridge traffic from sanctioned or abusive addresses on a given chain.
 */
interface IBlacklist {
    /**
     * @notice Returns whether `account` is blocked from initiating deposit-style outbound messages.
     */
    function isBlacklisted(address account) external view returns (bool);
}
