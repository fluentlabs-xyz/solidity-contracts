// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IBlacklist} from "../interfaces/IBlacklist.sol";
import {IFastWithdrawalList} from "../interfaces/IFastWithdrawalList.sol";
import {IGatewayBase} from "../interfaces/gateways/IGatewayBase.sol";
import {IFluentBridgeRead} from "../interfaces/bridge/IFluentBridge.sol";

/**
 * @title GatewayBase
 * @author Fluent Labs
 *
 * @notice Shared gateway foundation for cross-chain token gateways.
 * @dev UUPS-upgradeable base that centralizes:
 *      - common access control (`onlyOwner`, bridge-caller checks),
 *      - shared bridge routing config (`_bridgeContract`, `_otherSide`, `_otherSideChainId`),
 *      - optional outbound deposit blacklist (`_blacklistRegistry` + {_requireSenderNotBlacklisted}),
 *      - optimistic-withdrawal safety policy (`_whitelistEnabled` toggle + delegation to a
 *        shared {IFastWithdrawalList} for per-token rate limits),
 *      - common admin setters for bridge and remote gateway addresses.
 * @dev Storage is namespaced under ERC-7201 (`GatewayBaseStorage`) and consumed by derived gateways
 *      such as `NativeGateway` and `ERC20Gateway`.
 * @dev `onlyFluentBridge` enforces that receive entrypoints are callable only by the configured local
 *      `FluentBridge` instance.
 *
 * @notice Optimistic-withdrawal policy (`_consumeLimit`):
 *
 *  whitelistEnabled == false  →  no enforcement (legacy / unprotected mode)
 *
 *  whitelistEnabled == true:
 *      batch is FINALIZED (or no batch context)  →  unrestricted, no limits
 *      batch is PRECONFIRMED:
 *          token NOT in FastWithdrawalList  →  revert FastWithdrawalNotAllowed
 *          token IN FastWithdrawalList     →  FastWithdrawalList.consumeUsage (rate-limited)
 *
 *  Tokens not on the allowlist are still withdrawable — but only against finalized batches.
 *  This keeps optimistic withdrawals available for a curated set of tokens with explicit caps,
 *  while preserving the safer slow path for everything else.
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
        /// @dev Master switch for the optimistic-withdrawal safety policy. While `false`,
        ///      {_consumeLimit} is a no-op. While `true`, the policy described in the
        ///      contract NatSpec applies. Cannot be turned on without {_fastWithdrawalList}.
        bool _whitelistEnabled;
        /// @dev Shared {IFastWithdrawalList} address. Required to be non-zero whenever
        ///      `_whitelistEnabled` is `true` — enforced atomically at the toggle setter.
        address _fastWithdrawalList;
        /// @dev Reserved for future storage fields.
        uint256[48] __gap;
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
        return _getGatewayBaseStorage()._bridgeContract;
    }

    /// @inheritdoc IGatewayBase
    function getOtherSideGateway() public view returns (address) {
        return _getGatewayBaseStorage()._otherSideGateway;
    }

    /// @inheritdoc IGatewayBase
    function getOtherSideChainId() public view returns (uint256) {
        return _getGatewayBaseStorage()._otherSideChainId;
    }

    /// @inheritdoc IGatewayBase
    function getBlacklistRegistry() public view returns (address) {
        return _getGatewayBaseStorage()._blacklistRegistry;
    }

    /// @inheritdoc IGatewayBase
    function isWhitelistEnabled() public view virtual returns (bool) {
        return _getGatewayBaseStorage()._whitelistEnabled;
    }

    /// @inheritdoc IGatewayBase
    function getFastWithdrawalList() public view returns (address) {
        return _getGatewayBaseStorage()._fastWithdrawalList;
    }

    // ============ Admin functions ============

    /// @inheritdoc IGatewayBase
    function setBridgeContract(address newBridgeContract) external onlyOwner {
        _setBridgeContract(newBridgeContract);
    }

    /// @dev Validates and stores the local bridge address. Reverts on zero address.
    function _setBridgeContract(address newBridgeContract) internal {
        require(newBridgeContract != address(0), ZeroAddressNotAllowed("newBridgeContract"));
        GatewayBaseStorage storage $ = _getGatewayBaseStorage();
        emit BridgeContractUpdated($._bridgeContract, newBridgeContract);
        $._bridgeContract = newBridgeContract;
    }

    /// @inheritdoc IGatewayBase
    function setOtherSideGateway(address newOtherSideGateway) external onlyOwner {
        _setOtherSideGateway(newOtherSideGateway);
    }

    /// @dev Validates and stores the remote gateway address. Reverts on zero address.
    function _setOtherSideGateway(address newOtherSideGateway) internal {
        require(newOtherSideGateway != address(0), ZeroAddressNotAllowed("newOtherSideGateway"));
        GatewayBaseStorage storage $ = _getGatewayBaseStorage();
        emit OtherSideGatewayUpdated($._otherSideGateway, newOtherSideGateway);
        $._otherSideGateway = newOtherSideGateway;
    }

    /// @inheritdoc IGatewayBase
    function setOtherSideChainId(uint256 newOtherSideChainId) external onlyOwner {
        require(newOtherSideChainId != 0, ZeroValueNotAllowed("newOtherSideChainId"));
        _setOtherSideChainId(newOtherSideChainId);
    }

    /// @dev Internal setter allows `0` (e.g. beacon-based `ERC20Gateway.setOtherSide` clears universal-chain routing).
    function _setOtherSideChainId(uint256 newOtherSideChainId) internal {
        GatewayBaseStorage storage $ = _getGatewayBaseStorage();
        emit OtherSideChainIdUpdated($._otherSideChainId, newOtherSideChainId);
        $._otherSideChainId = newOtherSideChainId;
    }

    /// @inheritdoc IGatewayBase
    function setBlacklistRegistry(address newBlacklistRegistry) external onlyOwner {
        _setBlacklistRegistry(newBlacklistRegistry);
    }

    /// @dev Persists the blacklist registry. Zero address disables enforcement.
    function _setBlacklistRegistry(address newBlacklistRegistry) internal {
        GatewayBaseStorage storage $ = _getGatewayBaseStorage();
        emit BlacklistRegistryUpdated($._blacklistRegistry, newBlacklistRegistry);
        $._blacklistRegistry = newBlacklistRegistry;
    }

    /// @inheritdoc IGatewayBase
    function setFastWithdrawalList(address newFastWithdrawalList) external onlyOwner {
        _setFastWithdrawalList(newFastWithdrawalList);
    }

    /// @dev Stores the {IFastWithdrawalList} address. Clearing (passing `address(0)`) is
    ///      blocked while the whitelist is enabled, so the contract can never be in the
    ///      "enabled but no list" state described by {FastWithdrawalListNotConfigured}.
    function _setFastWithdrawalList(address newFastWithdrawalList) internal {
        GatewayBaseStorage storage $ = _getGatewayBaseStorage();
        if (newFastWithdrawalList == address(0)) {
            require(!$._whitelistEnabled, FastWithdrawalListNotConfigured());
        }
        emit FastWithdrawalListUpdated($._fastWithdrawalList, newFastWithdrawalList);
        $._fastWithdrawalList = newFastWithdrawalList;
    }

    /// @inheritdoc IGatewayBase
    function setWhitelistEnabled(bool enabled) external onlyOwner {
        _setWhitelistEnabled(enabled);
    }

    /// @dev Persists the whitelist toggle and emits {WhitelistEnabledUpdated}. Reverts when
    ///      attempting to enable without a configured {IFastWithdrawalList}, so the runtime
    ///      "enabled but no list" misconfiguration is structurally unreachable.
    function _setWhitelistEnabled(bool enabled) internal {
        GatewayBaseStorage storage $ = _getGatewayBaseStorage();
        if (enabled) {
            require($._fastWithdrawalList != address(0), FastWithdrawalListNotConfigured());
        }
        $._whitelistEnabled = enabled;
        emit WhitelistEnabledUpdated(enabled);
    }

    // ============ Shared safety helpers ============

    /// @dev Reverts with {AddressBlacklisted} if `account` is listed when a registry is configured.
    function _requireAccountNotBlacklisted(address account) internal view {
        address registry = _getGatewayBaseStorage()._blacklistRegistry;
        if (registry == address(0)) return;
        require(!IBlacklist(registry).isBlacklisted(account), AddressBlacklisted(account));
    }

    /**
     * @dev True iff the local bridge reports that the currently executing receive belongs to
     *      an L1 batch in {BatchStatus.Preconfirmed}. False on L2, on the L1 relayer path,
     *      and outside any receive execution.
     *
     *      The bridge-side accessor reads an EIP-1153 transient slot that
     *      {L1FluentBridge.receiveMessageWithProof} sets to the exact originating
     *      `batchIndex` for the duration of the receive — so this gives us "did THIS message
     *      come from a Preconfirmed batch", not the weaker "is any batch currently
     *      Preconfirmed" signal.
     */
    function _isFromPreconfirmedBatch() internal view returns (bool) {
        address bridgeAddr = _getGatewayBaseStorage()._bridgeContract;
        // Defensive: during initialization or misconfiguration the bridge can be unset; in
        // that case there is definitionally no batch context.
        if (bridgeAddr == address(0)) return false;
        return IFluentBridgeRead(bridgeAddr).isCurrentBatchPreconfirmed();
    }

    /**
     * @dev Optimistic-withdrawal safety gate, called by every receive function on every
     *      derived gateway. Behaviour matrix:
     *
     *      whitelistEnabled == false                                                 → no-op
     *      whitelistEnabled == true && batch is NOT Preconfirmed                     → no-op
     *      whitelistEnabled == true && batch IS Preconfirmed && token NOT in list    → revert
     *      whitelistEnabled == true && batch IS Preconfirmed && token IN list        → consume
     *
     *      "no batch context" (relayer-delivered or L2 receive) is treated like Finalized —
     *      not Preconfirmed — so it skips the gate. Limits exist specifically to bound the
     *      blast radius of a fraudulent batch during the optimistic preconfirmation window;
     *      anything outside that window is either trusted (Finalized) or out of scope
     *      (relayer / L2 paths have no rollup batch concept).
     *
     *      `tokenKey` is the ERC20 address for token withdrawals, or the native-asset sentinel
     *      (`NativeGateway.NATIVE_LIMIT_KEY`) for native ETH. The {IFastWithdrawalList} alias
     *      mechanism lets admin route multiple physical tokens (e.g. ETH + WETH) into a single
     *      shared rate-cap bucket so attackers can't drain twice the cap by exploiting both
     *      gateways in parallel.
     */
    function _consumeLimit(address tokenKey, uint256 amount) internal {
        GatewayBaseStorage storage $ = _getGatewayBaseStorage();
        if (!$._whitelistEnabled) return;
        if (!_isFromPreconfirmedBatch()) return;

        address list = $._fastWithdrawalList;
        // Defence in depth: the toggle setter already prevents this state, but assert it here
        // too in case of a future code path that ends up here without going through the setter.
        require(list != address(0), FastWithdrawalListNotConfigured());

        IFastWithdrawalList registry = IFastWithdrawalList(list);
        // Tokens not registered for fast withdrawal must wait for finalization.
        require(registry.isRegistered(tokenKey), FastWithdrawalNotAllowed(tokenKey));

        // Caps + window bookkeeping live in the shared registry. Reverts inside `consumeUsage`
        // bubble up; the receive call rolls back without consuming a nonce.
        registry.consumeUsage(tokenKey, amount);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
