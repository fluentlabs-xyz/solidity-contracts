// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IGateway {
    /****
     * Errors
     ***********
     */

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

    /// @dev Thrown when msg.value does not match expected native amount.
    /// @dev selector: 0x44e8bd2c
    error InvalidNativeAmount();

    /// @dev Thrown when native token transfer fails.
    /// @dev selector: 0xf4b3b1bc
    error NativeTransferFailed();

    /// @dev Thrown when the address is zero.
    /// @dev selector: 0xd92e233d
    error ZeroAddress();

    /// @dev Thrown when the recipient is zero.
    /// @dev selector: 0x9c8d2cd2
    error InvalidRecipient();

    /****
     * Events
     ***********
     */

    /// @dev Emitted when tokens are received.
    event ReceivedTokens(address source, address target, uint256 amount);

    /// @dev Emitted when the token mapping is updated.
    event UpdateTokenMapping(address indexed _peggedToken, address indexed _oldOriginToken, address indexed _newOriginToken);

    /// @dev Emitted when the other side is updated.
    event OtherSideUpdated(
        address indexed _oldOtherSide,
        address indexed _newOtherSide,
        address indexed _oldImplementation,
        address _newImplementation,
        address _oldFactory,
        address _newFactory
    );

    event TokenFactoryUpdated(address indexed oldTokenFactory, address indexed newTokenFactory);

    event OtherSideGatewayUpdated(address indexed oldOtherSide, address indexed newOtherSide);

    event OtherSideTokenImplementationUpdated(address indexed oldImplementation, address indexed newImplementation);

    /****
     * Functions
     ***********
     */

    /**
     * @notice Sends native tokens to the other side.
     * @param _to The address of the recipient on the other side.
     * @param _amount The amount of native tokens to send.
     */
    function sendNativeTokens(address _to, uint256 _amount) external payable;

    /**
     * @notice Sends tokens to the other side.
     * @param _token The address of the token to send.
     * @param _to The address of the recipient on the other side.
     * @param _amount The amount of tokens to send.
     */
    function sendTokens(address _token, address _to, uint256 _amount) external;

    /**
     * @notice Receives native tokens from the other side.
     * @param _from The address of the sender on the other side.
     * @param _to The address of the recipient on the local side.
     * @param _amount The amount of native tokens to receive.
     */
    function receiveNativeTokens(address _from, address _to, uint256 _amount) external payable;

    /**
     * @notice Receives tokens from the other side.
     * @param _originToken The address of the origin token.
     * @param _from The address of the sender on the other side.
     * @param _to The address of the recipient on the local side.
     * @param _amount The amount of tokens to receive.
     */
    function receiveOriginTokens(address _originToken, address _from, address _to, uint256 _amount) external payable;

    /**
     * @notice Receives pegged tokens from the other side.
     * @param _originToken The address of the origin token.
     * @param _peggedToken The address of the pegged token.
     * @param _from The address of the sender on the other side.
     * @param _to The address of the recipient on the local side.
     * @param _amount The amount of tokens to receive.
     * @param _tokenMetadata The metadata of the token (symbol, name, decimals)
     */
    function receivePeggedTokens(
        address _originToken,
        address _peggedToken,
        address _from,
        address _to,
        uint256 _amount,
        bytes calldata _tokenMetadata
    ) external payable;

    /**
     * @notice Computes the address of a pegged token for a given token for the other side.
     * @param _token The address of the token to compute the pegged token address for.
     * @return The address of the pegged token.
     */
    function computeOtherSidePeggedTokenAddress(address _token) external view returns (address);

    /**
     * @notice Computes the local pegged token address for a given origin token.
     * @param _originToken The origin token address used for local CREATE2 prediction.
     * @return The address of the pegged token.
     */
    function computePeggedTokenAddress(address _originToken) external view returns (address);
}
