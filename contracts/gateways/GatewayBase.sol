// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IBlacklist} from "../interfaces/IBlacklist.sol";
import {IGatewayBase} from "../interfaces/gateways/IGatewayBase.sol";

/**
 * @title GatewayBase
 * @author Fluent Labs
 *
 * @notice Shared gateway foundation for cross-chain token gateways.
 * @dev UUPS-upgradeable base that centralizes:
 *      - common access control (`onlyOwner`, bridge-caller checks),
 *      - shared bridge routing config (`_bridgeContract`, `_otherSide`, `_otherSideChainId`),
 *      - optional outbound deposit blacklist (`_blacklistRegistry` + {_requireSenderNotBlacklisted}),
 *      - common admin setters for bridge and remote gateway addresses.
 * @dev Storage is namespaced under ERC-7201 (`GatewayBaseStorage`) and consumed by derived gateways
 *      such as `NativeGateway` and `ERC20Gateway`.
 * @dev `onlyFluentBridge` enforces that receive entrypoints are callable only by the configured local
 *      `FluentBridge` instance.
 */
abstract contract GatewayBase is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable, IGatewayBase {
    // ============ Constants ============

    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.GatewayBaseStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GATEWAY_BASE_STORAGE_LOCATION = 0x96d2d562565fa04c409a57bcf4eeb472b5eafb489b00a26ae2441efb4f4ecc00;

    /// @custom:storage-location erc7201:Fluent.storage.GatewayBaseStorage
    struct GatewayBaseStorage {
        /// @dev Local FluentBridge address used for cross-chain message dispatch.
        address _bridgeContract;
        /// @dev Address of the corresponding gateway on the other chain.
        address _otherSideGateway;
        /// @dev Chain ID of the remote chain.
        uint256 _otherSideChainId;
        /// @dev Optional {IBlacklist}; address(0) disables deposit blacklist checks.
        address _blacklistRegistry;
        /// @dev Reserved for future storage fields.
        uint256[50] __gap;
    }

    /// @dev Returns the ERC-7201 storage pointer for gateway base state.
    function _getGatewayBaseStorage() internal pure returns (GatewayBaseStorage storage $) {
        assembly ("memory-safe") {
            $.slot := GATEWAY_BASE_STORAGE_LOCATION
        }
    }

    /**
     * @dev Restricts function to be callable only by the configured local FluentBridge.
     */
    modifier onlyFluentBridge() {
        // only the local bridge can relay cross-chain messages into the gateway
        require(msg.sender == _getGatewayBaseStorage()._bridgeContract, OnlyFluentBridge());
        _;
    }

    /**
     * @dev Initializes ownership, proxy, reentrancy guard, and gateway routing config.
     */
    function __GatewayBase_init(address initialOwner, address bridgeContract) internal onlyInitializing {
        // fail fast on zero addresses to prevent bricked proxies
        require(initialOwner != address(0) && bridgeContract != address(0), ZeroAddressNotAllowed("initialOwner or bridgeContract"));

        // two-step ownership prevents accidental transfers to wrong addresses
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        // reentrancy guard protects value-carrying gateway functions
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // ============ Storage ============
        _setBridgeContract(bridgeContract);
    }

    // ============ Public getters ============

    /// @inheritdoc IGatewayBase
    function getBridgeContract() public view returns (address) {
        // used by derived gateways to dispatch cross-chain messages via FluentBridge
        return _getGatewayBaseStorage()._bridgeContract;
    }

    /// @inheritdoc IGatewayBase
    function getOtherSideGateway() public view returns (address) {
        // target address encoded into cross-chain messages as the remote receiver
        return _getGatewayBaseStorage()._otherSideGateway;
    }

    /// @inheritdoc IGatewayBase
    function getOtherSideChainId() public view returns (uint256) {
        // chain ID passed to the bridge to route messages to the correct remote chain
        return _getGatewayBaseStorage()._otherSideChainId;
    }

    /// @inheritdoc IGatewayBase
    function getBlacklistRegistry() public view returns (address) {
        return _getGatewayBaseStorage()._blacklistRegistry;
    }

    // ============ Admin functions ============

    /// @inheritdoc IGatewayBase
    function setBridgeContract(address newBridgeContract) external onlyOwner {
        _setBridgeContract(newBridgeContract);
    }

    /**
     * @dev Validates and stores the local bridge address. Reverts on zero address.
     */
    function _setBridgeContract(address newBridgeContract) internal {
        require(newBridgeContract != address(0), ZeroAddressNotAllowed("newBridgeContract"));
        GatewayBaseStorage storage $ = _getGatewayBaseStorage();
        // emit before write so the event captures the previous value
        emit BridgeContractUpdated($._bridgeContract, newBridgeContract);
        $._bridgeContract = newBridgeContract;
    }

    /// @inheritdoc IGatewayBase
    function setOtherSideGateway(address newOtherSideGateway) external onlyOwner {
        _setOtherSideGateway(newOtherSideGateway);
    }

    /**
     * @dev Validates and stores the remote gateway address. Reverts on zero address.
     */
    function _setOtherSideGateway(address newOtherSideGateway) internal {
        require(newOtherSideGateway != address(0), ZeroAddressNotAllowed("newOtherSideGateway"));
        GatewayBaseStorage storage $ = _getGatewayBaseStorage();
        // emit before write so the event captures the previous value
        emit OtherSideGatewayUpdated($._otherSideGateway, newOtherSideGateway);
        $._otherSideGateway = newOtherSideGateway;
    }

    /// @inheritdoc IGatewayBase
    function setOtherSideChainId(uint256 newOtherSideChainId) external onlyOwner {
        // external setter disallows zero to prevent misconfiguration
        require(newOtherSideChainId != 0, ZeroValueNotAllowed("newOtherSideChainId"));
        _setOtherSideChainId(newOtherSideChainId);
    }

    /// @dev Internal setter allows `0` (e.g. beacon-based `ERC20Gateway.setOtherSide` clears universal-chain routing).
    function _setOtherSideChainId(uint256 newOtherSideChainId) internal {
        GatewayBaseStorage storage $ = _getGatewayBaseStorage();
        // emit before write so the event captures the previous value
        emit OtherSideChainIdUpdated($._otherSideChainId, newOtherSideChainId);
        $._otherSideChainId = newOtherSideChainId;
    }

    /// @inheritdoc IGatewayBase
    function setBlacklistRegistry(address newBlacklistRegistry) external onlyOwner {
        _setBlacklistRegistry(newBlacklistRegistry);
    }

    /**
     * @dev Persists the blacklist registry. Zero address disables enforcement.
     */
    function _setBlacklistRegistry(address newBlacklistRegistry) internal {
        GatewayBaseStorage storage $ = _getGatewayBaseStorage();
        emit BlacklistRegistryUpdated($._blacklistRegistry, newBlacklistRegistry);
        $._blacklistRegistry = newBlacklistRegistry;
    }

    /**
     * @dev Reverts with {AddressBlacklisted} if `account` is listed when a registry is configured.
     */
    function _requireAccountNotBlacklisted(address account) internal view {
        address registry = _getGatewayBaseStorage()._blacklistRegistry;
        if (registry == address(0)) return;
        require(!IBlacklist(registry).isBlacklisted(account), AddressBlacklisted(account));
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
