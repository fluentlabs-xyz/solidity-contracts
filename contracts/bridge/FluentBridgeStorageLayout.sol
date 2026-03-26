// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {
    IFluentBridge,
    IFluentBridgeEvents,
    IFluentBridgeErrors,
    IFluentBridgeRead,
    IFluentBridgeAdmin
} from "../interfaces/bridge/IFluentBridge.sol";

/**
 * @title FluentBridgeStorageLayout
 * @author Fluent Labs
 * @dev ERC-7201 namespaced storage base for {FluentBridge}. Contains all storage fields,
 *      view getters, admin setters, and initialization logic.
 *
 * @notice DEFAULT_ADMIN_ROLE is a MULTI-SIG role that can perform admin actions.
 */
contract FluentBridgeStorageLayout is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    IFluentBridgeEvents,
    IFluentBridgeErrors,
    IFluentBridgeRead,
    IFluentBridgeAdmin
{
    // ============ Constants ============

    /**
     * @notice Default gas limit for message execution.
     */
    uint256 public constant DEFAULT_EXECUTE_GAS_LIMIT = 100_000;
    /**
     * @notice Role authorized to pause the contract.
     */
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /**
     * @notice Role authorized to send authorized messages (a trusted relayer or bridge controller).
     */
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.FluentBridgeStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant FLUENT_BRIDGE_STORAGE_LOCATION = 0xe2e0b7768cb35928615964d328c094191301065845ac8cd8ffc433ff2eae9300;

    // ============ Storage ============

    /// @custom:storage-location erc7201:fluent.storage.FluentBridgeStorage
    struct FluentBridgeStorage {
        /// @dev Gas limit forwarded to target during message execution.
        uint256 _executeGasLimit;
        /// @dev Next outbound message nonce (incremented on each sendMessage).
        uint256 _nonce;
        /// @dev Next expected inbound nonce (sequential enforcement for relayer path).
        uint256 _receivedNonce;
        /// @dev Set to the cross-chain sender during message execution; address(0) otherwise.
        address _nativeSender;
        /// @dev Address of the bridge contract on the other chain.
        address _otherBridge;
        /// @dev Execution result by message hash (None / Failed / Success).
        mapping(bytes32 => IFluentBridge.MessageStatus) _receivedMessage;
        /// @dev Address that receives fees charged on L2 outbound messages.
        address _feeTreasury;
        /// @dev Reserved for future storage fields.
        uint256[50] __gap;
    }

    /**
     * @dev Configuration parameters for bridge initialization.
     */
    struct InitConfiguration {
        /// @dev Address authorized to perform admin actions.
        address adminRole;
        /// @dev Address authorized to pause the contract.
        address pauserRole;
        /// @dev Address authorized to relay messages.
        address relayerRole;
        /// @dev Address of the bridge contract on the other chain.
        address otherBridge;
    }

    /**
     * @dev Initializes bridge storage from ABI-encoded {InitConfiguration}.
     *      Called once from {L1FluentBridge.initialize} and {L2FluentBridge.initialize} via the UUPS proxy.
     */
    function __FluentBridgeStorage_init(bytes memory data) internal onlyInitializing {
        // Initialize OpenZeppelin modules in dependency order
        __ReentrancyGuard_init();
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        // Decode the packed initialization payload into structured config
        InitConfiguration memory params = abi.decode(data, (InitConfiguration));

        // ==== setup roles ====
        // Admin and pauser are mandatory — the bridge cannot operate without governance
        require(params.adminRole != address(0), ZeroAddressNotAllowed("adminRole"));
        require(params.pauserRole != address(0), ZeroAddressNotAllowed("pauserRole"));

        // Admin can manage all other roles and upgrade the proxy
        _grantRole(DEFAULT_ADMIN_ROLE, params.adminRole);
        // Pauser can halt the bridge in emergencies
        _grantRole(PAUSER_ROLE, params.pauserRole);
        // Relayer is the trusted off-chain component that delivers messages
        _setRelayerRole(params.relayerRole);

        // Set the counterpart bridge address on the other chain
        _setOtherBridge(params.otherBridge);
        // Apply the default gas limit for message execution calls
        _setExecuteGasLimit(DEFAULT_EXECUTE_GAS_LIMIT);
    }

    // ============ IFluentBridgeRead ============

    /**
     * @notice Next outbound message nonce.
     */
    function getNonce() public view returns (uint256) {
        // Reads from ERC-7201 namespaced storage; starts at 0 and increments per sendMessage
        return _getFluentBridgeStorage()._nonce;
    }

    /**
     * @notice Next expected inbound received message nonce.
     */
    function getReceivedNonce() public view returns (uint256) {
        // Sequential enforcement: relayer must deliver messages in nonce order
        return _getFluentBridgeStorage()._receivedNonce;
    }

    /**
     * @notice Cross-chain sender during message execution; address(0) otherwise.
     */
    function getNativeSender() public view returns (address) {
        // Non-zero only during message execution; allows the target to identify the L2 sender
        return _getFluentBridgeStorage()._nativeSender;
    }

    /// @inheritdoc IFluentBridgeRead
    function getOtherBridge() public view returns (address) {
        // The counterpart bridge on the opposite chain (L1 or L2)
        return _getFluentBridgeStorage()._otherBridge;
    }

    /**
     * @notice Status of a received message by its hash.
     */
    function getReceivedMessage(bytes32 key) public view returns (IFluentBridge.MessageStatus) {
        // Returns None if never processed, Success if delivered, Failed if execution reverted
        return _getFluentBridgeStorage()._receivedMessage[key];
    }

    /// @inheritdoc IFluentBridgeRead
    function getExecuteGasLimit() public view returns (uint256) {
        return _getFluentBridgeStorage()._executeGasLimit;
    }

    /// @inheritdoc IFluentBridgeRead
    function getFeeTreasury() public view returns (address) {
        return _getFluentBridgeStorage()._feeTreasury;
    }

    /// @inheritdoc IFluentBridgeRead
    function getSentMessageFee() public view virtual returns (uint256) {
        return 0;
    }

    // ============ IFluentBridgeAdmin ============

    /// @inheritdoc IFluentBridgeAdmin
    function setFeeTreasury(address newFeeTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Admin-gated — delegates to internal setter with zero-address validation
        _setFeeTreasury(newFeeTreasury);
    }

    /**
     * @dev Validates and stores a new fee treasury address. Reverts on zero address.
     */
    function _setFeeTreasury(address newFeeTreasury) internal {
        // Zero treasury would cause fee transfers to revert, breaking sendMessage
        require(newFeeTreasury != address(0), ZeroAddressNotAllowed("newFeeTreasury"));
        // Emit old and new values for off-chain tracking
        emit FeeTreasuryUpdated(getFeeTreasury(), newFeeTreasury);
        _getFluentBridgeStorage()._feeTreasury = newFeeTreasury;
    }

    /// @inheritdoc IFluentBridgeAdmin
    function setOtherBridge(address newOtherBridge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Admin-gated — delegates to internal setter with zero-address validation
        _setOtherBridge(newOtherBridge);
    }

    /**
     * @dev Validates and stores the other-chain bridge address. Reverts on zero address.
     */
    function _setOtherBridge(address newOtherBridge) internal {
        // The other bridge is the counterpart on the opposite chain; zero would break relaying
        require(newOtherBridge != address(0), ZeroAddressNotAllowed("otherBridge"));
        // Emit old/new pair so off-chain indexers can track the change
        emit OtherBridgeUpdated(getOtherBridge(), newOtherBridge);
        _getFluentBridgeStorage()._otherBridge = newOtherBridge;
    }

    /// @inheritdoc IFluentBridgeAdmin
    function setRelayerRole(address newRelayer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Admin-gated — adds a new relayer without revoking existing ones
        _setRelayerRole(newRelayer);
    }

    /**
     * @dev Grants the RELAYER_ROLE to the given address. Reverts on zero address.
     */
    function _setRelayerRole(address newRelayer) internal {
        // Relayer is the trusted authority that delivers cross-chain messages
        require(newRelayer != address(0), ZeroAddressNotAllowed("relayer"));
        // Note: this grants the role additively — previous relayers are not revoked
        _grantRole(RELAYER_ROLE, newRelayer);
    }

    /**
     * @notice Revokes RELAYER_ROLE from the given address.
     */
    function removeRelayerRole(address relayer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Revoke relayer access; the address can no longer deliver cross-chain messages
        _revokeRole(RELAYER_ROLE, relayer);
    }

    /**
     * @notice Revokes RELAYER_ROLE during an emergency without waiting for the admin timelock.
     * @param relayer Address to revoke relayer access from.
     */
    function emergencyRevokeRelayer(address relayer) external onlyRole(PAUSER_ROLE) {
        _revokeRole(RELAYER_ROLE, relayer);
    }

    /// @inheritdoc IFluentBridgeAdmin
    function setExecuteGasLimit(uint256 newExecuteGasLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Admin-gated — controls how much gas is forwarded to message targets
        _setExecuteGasLimit(newExecuteGasLimit);
    }

    /**
     * @dev Validates and stores the message execution gas limit. Reverts on zero value.
     */
    function _setExecuteGasLimit(uint256 newExecuteGasLimit) internal {
        // Zero gas limit would make all message executions fail with out-of-gas
        require(newExecuteGasLimit > 0, InvalidWindowConfig("executeGasLimit must be greater than 0"));
        emit ExecuteGasLimitUpdated(getExecuteGasLimit(), newExecuteGasLimit);
        _getFluentBridgeStorage()._executeGasLimit = newExecuteGasLimit;
    }
    // ============ Internal helpers ============

    /**
     * @dev Returns the current nonce and increments it (post-increment).
     */
    function _takeNextNonce() internal returns (uint256) {
        // Post-increment: returns current value, then advances for the next message
        return _getFluentBridgeStorage()._nonce++;
    }

    /**
     * @dev Returns the current received nonce and increments it (post-increment).
     */
    function _takeNextReceivedNonce() internal returns (uint256) {
        // Post-increment: enforces sequential delivery of inbound messages
        return _getFluentBridgeStorage()._receivedNonce++;
    }

    /**
     * @dev ABI-encodes a cross-chain message for hashing.
     */
    function _encodeMessage(
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 nonce,
        bytes calldata message
    ) internal pure returns (bytes memory) {
        // ABI-encode all message fields into a deterministic byte sequence
        // The keccak256 of this encoding is used as the Merkle leaf and status key
        return abi.encode(from, to, value, chainId, blockNumber, nonce, message);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /// @dev returns the storage pointer for the FluentBridgeStorage struct.
    function _getFluentBridgeStorage() internal pure returns (FluentBridgeStorage storage $) {
        // ERC-7201: derive storage slot from a deterministic hash so it does not
        // collide with inherited contract storage even if the inheritance chain changes
        assembly ("memory-safe") {
            $.slot := FLUENT_BRIDGE_STORAGE_LOCATION
        }
    }
}
