// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IGatewayErrors {
    /**
     * @dev Thrown when the caller is not the configured FluentBridge contract.
     * @dev selector: 0xacba36a5
     */
    error OnlyFluentBridge();

    /**
     * @dev Thrown when bridge-native sender does not match the configured remote gateway.
     * @dev selector: TODO
     */
    error MessageFromWrongGateway();

    /**
     * @dev Thrown when a value is zero.
     */
    error ZeroValueNotAllowed(string field);

    /**
     * @dev Thrown when an address is zero.
     */
    error ZeroAddressNotAllowed(string field);

    /**
     * @notice Thrown when the recipient is zero.
     * @dev selector: TODO
     */
    error InvalidRecipient();
}

interface IGatewayEvents {
    /**
     * @notice Emitted when tokens are received.
     */
    event ReceivedTokens(address indexed source, address indexed target, uint256 amount);

    /**
     * @notice Emitted when the token mapping is updated.
     */
    event UpdateTokenMapping(address indexed _peggedToken, address indexed _oldOriginToken, address indexed _newOriginToken);

    /**
     * @notice Emitted when the other side is updated.
     */
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
     * @notice Emitted when the gas limit is updated.
     */
    event GasLimitUpdated(uint256 prevValue, uint256 newValue);

    /**
     * @notice Emitted when the other side chain id is updated.
     */
    event OtherSideChainIdUpdated(uint256 indexed prevValue, uint256 indexed newValue);
}

interface IGateway is IGatewayErrors, IGatewayEvents {
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
}
