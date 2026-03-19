// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IGatewayErrors {
    /// @dev Thrown when the caller is not the configured local bridge contract.
    /// @dev selector: 0xf591effd
    error OnlyBridgeSender();

    /// @dev Thrown when bridge-native sender does not match the configured remote gateway.
    /// @dev selector: 0xa5c0236c
    error MessageFromWrongGateway();

    /// @dev Thrown when a message unexpectedly includes ETH value.
    /// @dev selector: 0xde373c7e
    error MessageValueMustBeZero();

    /// @dev Thrown when the origin token is zero.
    /// @dev selector: 0x690be5f9
    error OriginTokenZero();

    /// @dev Thrown when the pegged token is wrong.
    /// @dev selector: 0x164f4f0e
    error WrongPeggedToken();

    /// @dev Thrown when the token mapping check failed.
    /// @dev selector: 0xc0260b4c
    error TokenMappingCheckFailed();

    /// @dev Thrown when the token address is zero.
    /// @dev selector: 0x81c609f7
    error TokenAddressZero();

    /// @dev Thrown when an admin mapping update targets a token that has not been registered as pegged.
    error UnknownPeggedToken();

    /// @dev Thrown when the address is zero.
    /// @dev selector: 0xd92e233d
    error ZeroAddress();

    /// @notice Thrown when a supplied gas limit is zero or otherwise invalid for gateway execution.
    /// @dev Raised by gas-limit validation (e.g. `setGasLimit`) when the configured `_gasLimit` would render
    ///      cross-chain native transfers unsafe or non-functional.
    error InvalidGasLimit();
}

interface IGatewayEvents {
    /// @dev Emitted when tokens are received.
    event ReceivedTokens(address indexed source, address indexed target, uint256 amount);

    /// @dev Emitted when the token mapping is updated.
    event UpdateTokenMapping(address indexed _peggedToken, address indexed _oldOriginToken, address indexed _newOriginToken);

    /// @dev Emitted when the other side is updated.
    event OtherSideUpdated(
        address indexed _oldOtherSide,
        address indexed _newOtherSide,
        address indexed _oldImplementation,
        address _newImplementation,
        address _oldFactory,
        address _newFactory,
        address _oldBeacon,
        address _newBeacon
    );

    /**
     * @notice Emitted when the token factory is updated.
     */
    event TokenFactoryUpdated(address indexed prevValue, address indexed newValue);

    event OtherSideGatewayUpdated(address indexed prevValue, address indexed newValue);

    event OtherSideTokenImplementationUpdated(address indexed prevValue, address indexed newValue);

    /// @notice Emitted when the address of the bridge contract is updated.
    event BridgeContractUpdated(address indexed prevValue, address indexed newValue);

    /**
     * @notice Emitted when the gas limit is updated.
     */
    event GasLimitUpdated(uint256 prevValue, uint256 newValue);
}

interface IGateway is IGatewayErrors, IGatewayEvents {}
