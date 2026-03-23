// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title INativeGatewayErrors
 * @dev Custom errors for the native ETH gateway.
 */
interface INativeGatewayErrors {
    /**
     * @notice Thrown when msg.value does not match expected native amount.
     * @dev selector: 0x44e8bd2c
     */
    error InvalidNativeAmount();

    /**
     * @notice Thrown when native token transfer fails.
     * @dev selector: 0xf4b3b1bc
     */
    error NativeTransferFailed();

    /**
     * @notice Thrown when a supplied gas limit is zero or otherwise invalid for gateway execution.
     * @dev Raised by gas-limit validation (e.g. `setGasLimit`) when the configured `_gasLimit` would render
     *      cross-chain native transfers unsafe or non-functional.
     * @dev selector: 0x98bdb2e0
     */
    error InvalidGasLimit();
}

/**
 * @title INativeGateway
 * @dev Native ETH bridging: send, receive, rescue, and gas limit configuration.
 */
interface INativeGateway is INativeGatewayErrors {
    /**
     * @notice Sends native tokens to the other side.
     * @param to The address of the recipient on the other side.
     */
    function sendNativeTokens(address to) external payable;

    /**
     * @notice Receives native tokens from the other side.
     * @param from The address of the sender on the other side.
     * @param to The address of the recipient on the local side.
     * @param amount The amount of native tokens to receive.
     */
    function receiveNativeTokens(address from, address to, uint256 amount) external payable;

    /**
     * @notice Rescues native tokens from the gateway.
     * @param to The address to send the native tokens to.
     * @param amount The amount of native tokens to rescue.
     */
    function rescueNative(address payable to, uint256 amount) external;

    /**
     * @notice Sets the gas limit for the bridge.
     * @param newGasLimit The new gas limit.
     *
     * @dev Emits GasLimitUpdated
     */
    function setGasLimit(uint256 newGasLimit) external;

    /**
     * @notice Gets the gas limit for the bridge.
     * @return The gas limit for the bridge.
     */
    function getGasLimit() external view returns (uint256);
}
