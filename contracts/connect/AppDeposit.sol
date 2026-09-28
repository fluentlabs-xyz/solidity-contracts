// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IStakeManager} from "account-abstraction/interfaces/IStakeManager.sol";

import {IAppDeposit} from "../interfaces/connect/IAppDeposit.sol";

/**
 * @title AppDeposit
 * @notice Funds a Fluent Connect App: forwards the whole value into a paymaster's EntryPoint v0.7
 *         deposit and names the App in an event, which the settler credits as a Deposit.
 * @dev Stateless by design: no owner, no storage, no upgrade path. The paymaster is an argument;
 *      the settler refuses a Deposit whose paymaster is not the Network's sponsorship paymaster.
 */
contract AppDeposit is IAppDeposit {
    /// @notice EntryPoint v0.7, at the same address on every Network.
    IStakeManager public constant ENTRY_POINT = IStakeManager(0x0000000071727De22E5E9d8BAf0edAc6f37da032);

    /// @dev Every App id is a 36-byte UUID string.
    uint256 private constant APP_ID_LENGTH = 36;

    /// @inheritdoc IAppDeposit
    function deposit(string calldata appId, address paymaster) external payable {
        if (msg.value == 0) revert ZeroValue();
        if (bytes(appId).length != APP_ID_LENGTH) revert InvalidAppIdLength(bytes(appId).length);
        if (paymaster.code.length == 0) revert PaymasterHasNoCode(paymaster);

        ENTRY_POINT.depositTo{value: msg.value}(paymaster);
        emit Deposited(keccak256(bytes(appId)), paymaster, msg.sender, appId, msg.value);
    }
}
