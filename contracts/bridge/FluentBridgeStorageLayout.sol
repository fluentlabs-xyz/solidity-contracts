// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {Rollup} from "../rollup/Rollup.sol";
import {L2BlockHeader} from "../interfaces/IRollupTypes.sol";
import {Queue} from "../libraries/Queue.sol";
import {MerkleTree} from "../libraries/MerkleTree.sol";
import {ExcessivelySafeCall} from "../libraries/ExcessivelySafeCall.sol";

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
        /**
         * @notice Gas limit for message execution.
         */
        uint256 _executeGasLimit;
        /**
         * @notice Next outbound message nonce (incremented on each sendMessage).
         */
        uint256 _nonce;
        /**
         * @notice Next expected inbound received message nonce (L2 receiveMessage ordering).
         */
        uint256 _receivedNonce;
        /**
         * @notice During receive execution, the address that sent the message on the other chain; otherwise address(0).
         */
        address _nativeSender;
        /**
         * @notice Address of the bridge contract on the other chain.
         */
        address _otherBridge;
        /**
         * @notice Status of a received message by its hash (None, Failed, Success).
         */
        mapping(bytes32 => IFluentBridge.MessageStatus) _receivedMessage;
        /**
         * @notice Treasury address for refunding gas costs.
         */
        address _feeTreasury;
        /**
         * @notice Gap for future storage.
         */
        uint256[50] __gap;
    }

    /// @notice Configuration for the FluentBridge initialization.
    struct InitConfiguration {
        /**
         * @notice Address authorized to perform admin actions.
         */
        address adminRole;
        /**
         * @notice Address authorized to pause the contract.
         */
        address pauserRole;
        /**
         * @notice Address authorized to send authorized messages (a trusted relayer or bridge controller).
         */
        address relayerRole;
        /**
         * @notice Address of the bridge contract on the other chain.
         */
        address otherBridge;
    }

    /**
     * @dev Initializes bridge storage from ABI-encoded {InitConfiguration}.
     *      Called once from {FluentBridge.initialize} via the UUPS proxy.
     */
    function __FluentBridgeStorage_init(bytes memory data) internal {
        __ReentrancyGuard_init();
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        InitConfiguration memory params = abi.decode(data, (InitConfiguration));

        // ==== setup roles ====
        require(params.adminRole != address(0), ZeroAddressNotAllowed("adminRole"));
        require(params.pauserRole != address(0), ZeroAddressNotAllowed("pauserRole"));

        _grantRole(DEFAULT_ADMIN_ROLE, params.adminRole);
        _grantRole(PAUSER_ROLE, params.pauserRole);
        _setRelayerRole(params.relayerRole);

        _setOtherBridge(params.otherBridge);
        _setExecuteGasLimit(DEFAULT_EXECUTE_GAS_LIMIT);
    }

    // ============ IFluentBridgeRead ============

    function getNonce() public view returns (uint256) {
        return _getFluentBridgeStorage()._nonce;
    }

    function getReceivedNonce() public view returns (uint256) {
        return _getFluentBridgeStorage()._receivedNonce;
    }

    function getNativeSender() public view returns (address) {
        return _getFluentBridgeStorage()._nativeSender;
    }

    function getOtherBridge() public view returns (address) {
        return _getFluentBridgeStorage()._otherBridge;
    }

    function getReceivedMessage(bytes32 key) public view returns (IFluentBridge.MessageStatus) {
        return _getFluentBridgeStorage()._receivedMessage[key];
    }

    function getExecuteGasLimit() public view returns (uint256) {
        return _getFluentBridgeStorage()._executeGasLimit;
    }

    function getFeeTreasury() public view returns (address) {
        return _getFluentBridgeStorage()._feeTreasury;
    }

    /// @inheritdoc IFluentBridgeRead
    function getSentMessageFee() public view virtual returns (uint256) {
        return 0;
    }

    // ============ IFluentBridgeAdmin ============

    function setFeeTreasury(address newFeeTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setFeeTreasury(newFeeTreasury);
    }

    function _setFeeTreasury(address newFeeTreasury) internal {
        require(newFeeTreasury != address(0), ZeroAddressNotAllowed("newFeeTreasury"));
        emit FeeTreasuryUpdated(getFeeTreasury(), newFeeTreasury);
        _getFluentBridgeStorage()._feeTreasury = newFeeTreasury;
    }

    function setOtherBridge(address newOtherBridge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setOtherBridge(newOtherBridge);
    }

    function _setOtherBridge(address newOtherBridge) internal {
        require(newOtherBridge != address(0), ZeroAddressNotAllowed("otherBridge"));
        emit OtherBridgeUpdated(getOtherBridge(), newOtherBridge);
        _getFluentBridgeStorage()._otherBridge = newOtherBridge;
    }

    function setRelayerRole(address newRelayer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRelayerRole(newRelayer);
    }

    function _setRelayerRole(address newRelayer) internal {
        require(newRelayer != address(0), ZeroAddressNotAllowed("relayer"));
        _grantRole(RELAYER_ROLE, newRelayer);
    }

    function removeRelayerRole(address relayer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(RELAYER_ROLE, relayer);
    }

    function setExecuteGasLimit(uint256 newExecuteGasLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setExecuteGasLimit(newExecuteGasLimit);
    }

    function _setExecuteGasLimit(uint256 newExecuteGasLimit) internal {
        require(newExecuteGasLimit > 0, InvalidWindowConfig("executeGasLimit must be greater than 0"));
        emit ExecuteGasLimitUpdated(getExecuteGasLimit(), newExecuteGasLimit);
        _getFluentBridgeStorage()._executeGasLimit = newExecuteGasLimit;
    }
    // ============ Internal helpers ============

    function _takeNextNonce() internal returns (uint256) {
        return _getFluentBridgeStorage()._nonce++;
    }

    function _takeNextReceivedNonce() internal returns (uint256) {
        return _getFluentBridgeStorage()._receivedNonce++;
    }

    function _encodeMessage(
        address _from,
        address _to,
        uint256 _value,
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _nonce,
        bytes calldata _message
    ) internal pure returns (bytes memory) {
        return abi.encode(_from, _to, _value, _chainId, _blockNumber, _nonce, _message);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /// @dev returns the storage pointer for the FluentBridgeStorage struct.
    function _getFluentBridgeStorage() internal pure returns (FluentBridgeStorage storage $) {
        assembly {
            $.slot := FLUENT_BRIDGE_STORAGE_LOCATION
        }
    }
}
