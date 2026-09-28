// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title IAppDeposit
 * @author Fluent Labs
 * @notice Interface for the Fluent Connect AppDeposit contract
 * @dev Funds an App: the value goes into a paymaster's EntryPoint v0.7 deposit and the App is named
 *      in {Deposited}, which the Fluent Connect settler credits as a Deposit.
 */
interface IAppDeposit {
    /// @notice The call carried no value.
    error ZeroValue();

    /// @notice The App id is not 36 bytes long, the length of every App id.
    error InvalidAppIdLength(uint256 length);

    /// @notice The paymaster has no code, so it cannot be a paymaster.
    error PaymasterHasNoCode(address paymaster);

    /// @notice A Deposit for the App `appId`; `appIdHash` is `keccak256(bytes(appId))`, for topic filters.
    event Deposited(
        bytes32 indexed appIdHash, address indexed paymaster, address indexed from, string appId, uint256 amount
    );

    /**
     * @notice Deposits `msg.value` into `paymaster`'s EntryPoint deposit on behalf of the App `appId`.
     * @param appId The App id, exactly 36 bytes
     * @param paymaster The paymaster whose EntryPoint deposit is credited; must have code
     */
    function deposit(string calldata appId, address paymaster) external payable;
}
