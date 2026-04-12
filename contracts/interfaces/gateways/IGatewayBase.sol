// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title IGatewayBaseErrors
 * @dev Custom errors for the gateway base contract.
 */
interface IGatewayBaseErrors {
    /**
     * @notice Thrown when the caller is not the configured FluentBridge contract.
     * @dev selector: 0xacba36a5
     */
    error OnlyFluentBridge();

    /**
     * @notice Thrown when bridge-native sender does not match the configured remote gateway.
     * @dev selector: 0xa5c0236c
     */
    error MessageFromWrongGateway();

    /**
     * @notice Thrown when a value is zero.
     * @dev selector: 0x78bcc63a
     */
    error ZeroValueNotAllowed(string field);

    /**
     * @notice Thrown when an address is zero.
     * @dev selector: 0x44034241
     */
    error ZeroAddressNotAllowed(string field);

    /**
     * @notice Thrown when the recipient is zero.
     * @dev selector: 0x9c8d2cd2
     */
    error InvalidRecipient();

    /**
     * @notice Thrown when the caller does not have the required role.
     * @dev selector: 0x629e9f8b
     */
    error ExactFeeRequired();

    /**
     * @notice Outbound deposit rejected because the account is on the configured blacklist registry.
     * @dev selector: 0xdaf49ab9
     */
    error AddressBlacklisted(address account);
}

/**
 * @title IGatewayBaseEvents
 * @dev Events emitted by gateway contracts.
 */
interface IGatewayBaseEvents {
    /**
     * @notice Emitted when tokens are received.
     */
    event ReceivedTokens(address indexed source, address indexed target, uint256 amount);

    /**
     * @notice Emitted when the token mapping is updated.
     */
    event UpdateTokenMapping(address indexed peggedToken, address indexed oldOriginToken, address indexed newOriginToken);

    /**
     * @notice Emitted when the other side gateway, token implementation, factory, and beacon are updated.
     */
    event OtherSideUpdated(
        address indexed oldOtherSide,
        address indexed newOtherSide,
        address indexed oldImplementation,
        address newImplementation,
        address oldFactory,
        address newFactory,
        address oldBeacon,
        address newBeacon
    );

    /**
     * @notice Emitted when the token factory is updated.
     */
    event TokenFactoryUpdated(address indexed prevValue, address indexed newValue);

    /**
     * @notice Emitted when the other side gateway is updated.
     */
    event OtherSideGatewayUpdated(address indexed prevValue, address indexed newValue);

    /**
     * @notice Emitted when the other side token implementation is updated.
     */
    event OtherSideTokenImplementationUpdated(address indexed prevValue, address indexed newValue);

    /**
     * @notice Emitted when the address of the bridge contract is updated.
     */
    event BridgeContractUpdated(address indexed prevValue, address indexed newValue);

    /**
     * @notice Emitted when the other side chain id is updated.
     */
    event OtherSideChainIdUpdated(uint256 indexed prevValue, uint256 indexed newValue);

    /**
     * @notice Emitted when the blacklist registry address is updated.
     */
    event BlacklistRegistryUpdated(address indexed prevValue, address indexed newValue);
}

/**
 * @title IGatewayBase
 * @dev Admin and view functions shared by all gateway implementations.
 */
interface IGatewayBase is IGatewayBaseErrors, IGatewayBaseEvents {
    /**
     * @notice Returns the address of the bridge contract.
     * @return The address of the bridge contract.
     */
    function getBridgeContract() external view returns (address);

    /**
     * @notice Returns the address of the other side gateway.
     * @return The address of the other side gateway.
     */
    function getOtherSideGateway() external view returns (address);

    /**
     * @notice Returns the other side chain id.
     * @return The other side chain id.
     */
    function getOtherSideChainId() external view returns (uint256);

    /**
     * @notice Updates the bridge contract address used for sending and receiving messages.
     * @param newBridgeContract The address of the bridge contract.
     *
     * @dev Emits BridgeContractUpdated
     */
    function setBridgeContract(address newBridgeContract) external;

    /**
     * @notice Updates the other side gateway address used as message destination.
     * @param newOtherSideGateway The address of the other side gateway.
     *
     * @dev Emits OtherSideGatewayUpdated
     */
    function setOtherSideGateway(address newOtherSideGateway) external;

    /**
     * @notice Updates the other side chain id used for message destination.
     * @param newOtherSideChainId The new other side chain id.
     *
     * @dev Emits OtherSideChainIdUpdated
     */
    function setOtherSideChainId(uint256 newOtherSideChainId) external;

    /**
     * @notice Returns the optional {IBlacklist} registry consulted before outbound deposits; zero when disabled.
     */
    function getBlacklistRegistry() external view returns (address);

    /**
     * @notice Sets the blacklist registry for outbound deposit checks (zero disables enforcement).
     */
    function setBlacklistRegistry(address newBlacklistRegistry) external;
}
