// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {GatewayBase} from "./GatewayBase.sol";
import {FluentBridge} from "../bridge/FluentBridge.sol";

import {ITokenBridge} from "../interfaces/external/hyperlane/ITokenBridge.sol";
import {IL1HypNativeGateway} from "../interfaces/gateways/IHypNativeGateway.sol";

/**
 * @title L1HypNativeGateway
 * @author Fluent Labs
 *
 * @notice L1 receive gateway that re-quotes the Hyperlane v10 warp route at delivery and
 *         dispatches a native-ETH transfer to a remote chain.
 * @dev UUPS-upgradeable. Adds a per-domain warp route mapping in its own ERC-7201 namespace
 *      and inherits routing/blacklist from {GatewayBase}.
 *
 *      Cross-trust-boundary policy: applies the same {_consumeLimit} rate cap as
 *      {NativeGateway}, charged against the shared {NativeGateway-NATIVE_LIMIT_KEY} bucket on
 *      {FastWithdrawalList}. While the originating L1 batch is in {BatchStatus.Preconfirmed}
 *      the rate cap bounds optimistic forward dispatch; once Finalized the cap is a no-op.
 *      The shared key is mandatory — a separate bucket would let an attacker drain twice the
 *      cap by exploiting `NativeGateway` and this gateway in parallel within one optimistic
 *      window. The underlying safety at Preconfirmed comes from the Nitro proof verification
 *      that {BatchStatus.Preconfirmed} represents; the rate cap is defense-in-depth on top.
 *
 *      Fee handling: the bridge transports `amount + hypFee`. At delivery the gateway
 *      re-queries the warp route via {ITokenBridge.quoteTransferRemote} and forwards the sum
 *      of all three quote entries (dispatch gas + amount-with-internal-fee + external fee)
 *      from `address(this).balance` — which combines the bridge-transported value with the
 *      gateway's admin-funded native reserve. If the gateway balance is insufficient the call
 *      reverts and the bridge marks the message Failed, retryable via
 *      {FluentBridge.receiveFailedMessage} after the admin tops up the reserve.
 */
contract L1HypNativeGateway is GatewayBase, IL1HypNativeGateway {
    /// @dev Must match {NativeGateway-NATIVE_LIMIT_KEY} so both gateways debit the same
    ///      {IFastWithdrawalList} bucket and the per-window outflow stays bounded by ONE cap.
    ///      Empirically asserted by `test_sharedBucket_NativeGatewayPlusL1Hyp`.
    address public constant NATIVE_LIMIT_KEY = address(0x0000012345678901234567890123456789012345);

    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.L1HypNativeGatewayStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant L1_HYP_NATIVE_GATEWAY_STORAGE_LOCATION = 0x25bef2dd297f0ba6c2dc68712d58ece007c5787406c7d8b826d422fac42e9c00;

    /// @custom:storage-location erc7201:Fluent.storage.L1HypNativeGatewayStorage
    struct L1HypNativeGatewayStorage {
        /// @dev Per-Hyperlane-domain warp route configured by admin.
        mapping(uint32 domain => address warpRoute) _warpRouteFor;
        /// @dev Reserved for future storage fields.
        uint256[49] __gap;
    }

    function _getStorage() private pure returns (L1HypNativeGatewayStorage storage $) {
        assembly ("memory-safe") {
            $.slot := L1_HYP_NATIVE_GATEWAY_STORAGE_LOCATION
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the upgradeable gateway (replaces constructor when used behind a proxy).
     */
    function initialize(address initialOwner, address bridgeContract) public initializer {
        __GatewayBase_init(initialOwner, bridgeContract);
    }

    /// @inheritdoc IL1HypNativeGateway
    function receiveAndForwardNative(
        uint32 domain,
        bytes32 recipient,
        uint256 amount,
        address originSender
    ) external payable onlyFluentBridge nonReentrant {
        // Only the configured L2 peer is authorized to send through the bridge.
        require(
            FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(),
            MessageFromWrongGateway()
        );
        require(recipient != bytes32(0), ZeroRecipient());

        // Optimistic-withdrawal rate cap, shared with NativeGateway via NATIVE_LIMIT_KEY so the
        // combined per-window outflow across both gateways stays within a single configured cap.
        // No-op when whitelist is disabled or the source batch is already Finalized.
        _consumeLimit(NATIVE_LIMIT_KEY, amount);

        address warpRoute = _getStorage()._warpRouteFor[domain];
        require(warpRoute != address(0), UnsupportedDomain(domain));

        // Hyperlane v10 `TokenRouter.quoteTransferRemote` always returns 3 entries; for
        // HypNative all three are native ETH. A different length or a non-native entry means
        // the configured route isn't a HypNative variant — refuse rather than read past array
        // bounds or partially pay and get an opaque revert deeper in the stack.
        ITokenBridge.Quote[] memory quotes =
            ITokenBridge(warpRoute).quoteTransferRemote(domain, recipient, amount);
        require(quotes.length == 3, MalformedQuote(quotes.length));
        require(quotes[0].token == address(0), UnexpectedFeeToken(0, quotes[0].token));
        require(quotes[1].token == address(0), UnexpectedFeeToken(1, quotes[1].token));
        require(quotes[2].token == address(0), UnexpectedFeeToken(2, quotes[2].token));

        // The principal `amount` is already inside `quotes[1].amount`, so this is the *total*
        // (principal + every fee), not "fee only".
        uint256 totalNativeValue = quotes[0].amount + quotes[1].amount + quotes[2].amount;

        // `address(this).balance` = bridge-transported value (`amount + hypFee`) + admin
        // reserve. Reserve covers drift between L2-side quote and L1-side live quote. If even
        // the reserve can't close the gap → revert → bridge marks Failed → admin refills and
        // retries via `receiveFailedMessage`.
        uint256 available = address(this).balance;
        require(available >= totalNativeValue, ReserveDepleted(totalNativeValue, available));

        bytes32 messageId = ITokenBridge(warpRoute).transferRemote{value: totalNativeValue}(domain, recipient, amount);
        emit HyperlaneTransferDispatched(domain, recipient, amount, originSender, messageId);
    }

    /// @inheritdoc IL1HypNativeGateway
    function setWarpRoute(uint32 domain, address warpRoute) external onlyOwner {
        // address(0) clears the route; any non-zero value must be a contract — fail fast here
        // rather than letting the first delivery panic on quoteTransferRemote.
        require(warpRoute == address(0) || warpRoute.code.length > 0, WarpRouteNotAContract(warpRoute));
        L1HypNativeGatewayStorage storage $ = _getStorage();
        emit WarpRouteUpdated(domain, $._warpRouteFor[domain], warpRoute);
        $._warpRouteFor[domain] = warpRoute;
    }

    /// @inheritdoc IL1HypNativeGateway
    function getWarpRoute(uint32 domain) external view returns (address) {
        return _getStorage()._warpRouteFor[domain];
    }

    /// @inheritdoc IL1HypNativeGateway
    function rescueNative(address payable to, uint256 amount) external nonReentrant onlyOwner {
        require(to != address(0), InvalidRecipient());
        (bool success,) = to.call{value: amount}("");
        require(success, RescueFailed());
    }

    /// @dev Accepts bare ETH so the admin can top up the dispatch-fee reserve and Hyperlane
    ///      IGP overpayment refunds can accrue here for periodic sweep via {rescueNative}.
    receive() external payable {}
}
