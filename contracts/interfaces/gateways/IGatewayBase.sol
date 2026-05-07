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
     * @dev `account` is in canonical bytes32 form: Hyperlane left-padded (`bytes32(uint256(uint160(addr)))`)
     *      for EVM addresses, raw 32-byte identifier for non-EVM (e.g. Solana ed25519 keys).
     * @dev selector: 0x6b597076
     */
    error AddressBlacklisted(bytes32 account);

    /**
     * @notice Thrown when the batch status is invalid.
     * @dev selector: 0xf610563c
     */
    error InvalidBatchStatus();

    /**
     * @notice {setWhitelistEnabled(true)} called while {_fastWithdrawalList} is unset, OR
     *         a Preconfirmed-batch receive reached the consume step on a gateway whose
     *         {_fastWithdrawalList} address is zero. Either case is a misconfiguration:
     *         the rate-limit registry must be wired before optimistic withdrawals can be
     *         enforced safely.
     */
    error FastWithdrawalListNotConfigured();

    /**
     * @notice The originating L1 batch is `Preconfirmed` but `token` is not on the
     *         {IFastWithdrawalList} allowlist. The user must wait for the batch to reach
     *         `Finalized` before withdrawing this token, or the admin must register the
     *         token on the allowlist.
     */
    error FastWithdrawalNotAllowed(address token);
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
     * @notice Emitted when {ERC20Gateway}'s per-origin bridging exclusion is toggled.
     */
    event BridgingExcludedOriginUpdated(address indexed originToken, bool excluded);

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

    /**
     * @notice Emitted when whitelist enforcement is toggled. While `false`, {_consumeLimit}
     *         is a no-op and the gateway behaves as if no rate-limit policy were in place.
     */
    event WhitelistEnabledUpdated(bool enabled);

    /**
     * @notice Emitted when the {IFastWithdrawalList} address used for optimistic-withdrawal
     *         rate-limiting is updated. `address(0)` means "no list configured".
     */
    event FastWithdrawalListUpdated(address indexed prevValue, address indexed newValue);
}

/**
 * @title IGatewayBase
 * @dev Admin and view functions shared by all gateway implementations.
 */
interface IGatewayBase is IGatewayBaseErrors, IGatewayBaseEvents {
    /**
     * @notice Returns the address of the bridge contract.
     */
    function getBridgeContract() external view returns (address);

    /**
     * @notice Returns the address of the other side gateway.
     */
    function getOtherSideGateway() external view returns (address);

    /**
     * @notice Returns the other side chain id.
     */
    function getOtherSideChainId() external view returns (uint256);

    /**
     * @notice Updates the bridge contract address used for sending and receiving messages.
     *
     * @dev Emits BridgeContractUpdated
     */
    function setBridgeContract(address newBridgeContract) external;

    /**
     * @notice Updates the other side gateway address used as message destination.
     *
     * @dev Emits OtherSideGatewayUpdated
     */
    function setOtherSideGateway(address newOtherSideGateway) external;

    /**
     * @notice Updates the other side chain id used for message destination.
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
     *
     * @dev Emits BlacklistRegistryUpdated
     */
    function setBlacklistRegistry(address newBlacklistRegistry) external;

    /**
     * @notice Returns the {IFastWithdrawalList} contract used for optimistic-withdrawal rate
     *         limiting. Zero when no list is configured. While {isWhitelistEnabled} is `true`
     *         this MUST be non-zero — `setWhitelistEnabled(true)` reverts otherwise.
     */
    function getFastWithdrawalList() external view returns (address);

    /**
     * @notice Sets the {IFastWithdrawalList} contract address. Pass `address(0)` to clear
     *         (only allowed while {isWhitelistEnabled} is `false`).
     *
     * @dev Emits FastWithdrawalListUpdated
     */
    function setFastWithdrawalList(address newFastWithdrawalList) external;

    /**
     * @notice Enables or disables the optimistic-withdrawal safety policy. When `false`,
     *         {_consumeLimit} is a no-op (legacy / unprotected mode). When `true`, every
     *         receive on a Preconfirmed batch must either (a) target a token registered on
     *         the configured {IFastWithdrawalList} (consuming its rate cap) or (b) be
     *         rejected with {FastWithdrawalNotAllowed}.
     *
     * @dev Reverts {FastWithdrawalListNotConfigured} if `enabled == true` and the
     *      {IFastWithdrawalList} address has not been set.
     *
     * @dev Emits WhitelistEnabledUpdated
     */
    function setWhitelistEnabled(bool enabled) external;

    /**
     * @notice Returns whether the optimistic-withdrawal safety policy is currently enforced.
     */
    function isWhitelistEnabled() external view returns (bool);
}
