// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

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
}

/**
 * @title INativeGateway
 * @dev Native ETH bridging: send, receive, and rescue.
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
}
