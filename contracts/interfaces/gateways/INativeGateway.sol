// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface INativeGatewayErrors {
    /**
     * @notice Thrown when msg.value does not match expected native amount.
     * @dev selector: 0x44e8bd2c
     */
    error InvalidNativeAmount();

    /**
     * @notice Thrown when the recipient is zero.
     * @dev selector: TODO
     */
    error InvalidRecipient();

    /**
     * @notice Zero address supplied for a required configuration field.
     * @dev selector: TODO
     */
    error ZeroAddressNotAllowed(string field);

    /**
     * @notice Thrown when native token transfer fails.
     * @dev selector: 0xf4b3b1bc
     */
    error NativeTransferFailed();
}

interface INativeGateway is INativeGatewayErrors {
    /**
     * @notice Sends native tokens to the other side.
     * @param _to The address of the recipient on the other side.
     * @param _amount The amount of native tokens to send.
     */
    function sendNativeTokens(address _to, uint256 _amount) external payable;

    /**
     * @notice Receives native tokens from the other side.
     * @param _from The address of the sender on the other side.
     * @param _to The address of the recipient on the local side.
     * @param _amount The amount of native tokens to receive.
     */
    function receiveNativeTokens(address _from, address _to, uint256 _amount) external payable;
}
