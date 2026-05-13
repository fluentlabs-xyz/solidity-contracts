// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title IHypNativeGatewayErrors
 * @dev Custom errors shared by the native ETH Hyperlane gateway pair.
 */
interface IHypNativeGatewayErrors {
    /**
     * @notice No Hyperlane warp route has been configured on this gateway. Both directions
     *         (outbound `receiveAndForwardNative` and inbound `sendNativeTokens`) require a
     *         set warp route; the gateway refuses to dispatch / authorize otherwise.
     */
    error WarpRouteNotConfigured();

    /**
     * @notice The warp route returned a non-native fee token in one of the three quote entries.
     * @param quoteIndex Position in the `Quote[]` returned by `quoteTransferRemote` (0..2).
     * @param actualToken Non-native token address returned at that index.
     */
    error UnexpectedFeeToken(uint8 quoteIndex, address actualToken);

    /**
     * @notice The warp route returned a `Quote[]` of an unexpected length. Canonical HypNative
     *         always returns exactly 3 entries; any other length means the configured route
     *         isn't a HypNative variant (or is a malformed extension), so we refuse rather
     *         than reading past the array bounds.
     */
    error MalformedQuote(uint256 quotesLength);

    /**
     * @notice Live `quoteTransferRemote` exceeds the gateway balance (bridge-transported value
     *         plus the admin-funded native reserve).
     */
    error ReserveDepleted(uint256 required, uint256 available);

    /**
     * @notice Hyperlane recipient cannot be `bytes32(0)`. Beyond this minimal check, the
     *         destination router decodes whatever bytes32 it receives — formatting is the
     *         caller's responsibility.
     */
    error ZeroRecipient();

    /**
     * @notice The target domain is invalid (e.g., zero).
     */
    error InvalidTargetDomain();

    /**
     * @notice Admin attempted to set a warp route to a non-contract address.
     * @dev Zero address is rejected separately (`ZeroAddressNotAllowed`); any other value
     *      must have code at the given address.
     */
    error WarpRouteNotAContract(address warpRoute);

    /**
     * @notice The low-level call inside {rescueNative} returned `false`.
     */
    error RescueFailed();

    /**
     * @notice `msg.value` does not equal the encoded `amount`.
     * @dev Used by both directions: L2 outbound `sendNativeTokens` checks user-supplied
     *      `msg.value`, L2 inbound `receiveNativeTokens` checks the L1 bridge-delivered
     *      value matches the payload.
     */
    error InvalidNativeAmount(uint256 supplied, uint256 expected);

    /**
     * @notice L1 inbound: caller of {sendNativeTokens} is not the configured inbound warp
     *         route. Only `L1FluentHypNative` (a Hyperlane warp-route extension on Ethereum)
     *         is authorized to forward inbound transfers through this gateway.
     */
    error UnauthorizedWarpRoute();

    /**
     * @notice The low-level `recipient.call{value}("")` returned `false` on an inbound delivery.
     * @dev Same selector as {INativeGateway-NativeTransferFailed}; redefined here so the
     *      Hyperlane-gateway interface is self-contained.
     */
    error NativeTransferFailed();
}

/**
 * @title IHypNativeGatewayEvents
 * @dev Events emitted by the native ETH Hyperlane gateway pair.
 */
interface IHypNativeGatewayEvents {
    /**
     * @notice L1: Hyperlane warp route address was updated. Same field is used for both the
     *         outbound dispatch target and the inbound caller-auth — single source of truth.
     */
    event WarpRouteUpdated(address indexed prev, address indexed next);

    /**
     * @notice L1: emitted after a successful `transferRemote` dispatch.
     * @param domain Hyperlane destination domain.
     * @param recipient Destination address on the remote chain (bytes32 — left-padded for EVM).
     * @param amount Exact-out amount delivered to the recipient on the destination chain.
     * @param originSender L2 `msg.sender` of the originating {IL2HypNativeGateway.sendNativeTokens} call;
     *        attribution only, not used for authorization or refunds.
     * @param messageId Hyperlane message id returned by `transferRemote` — join key for the
     *        Hyperlane Explorer / GraphQL API.
     */
    event HyperlaneTransferDispatched(
        uint32 indexed domain,
        bytes32 indexed recipient,
        uint256 amount,
        address indexed originSender,
        bytes32 messageId
    );

    /**
     * @notice L2: emitted when a user initiates a native transfer through the gateway pair.
     * @dev Pairs with L1 `HyperlaneTransferDispatched` on the same `(sender, recipient, domain, amount)`
     *      tuple. Off-chain consumers can correlate the two to track the full lifecycle.
     * @param domain Hyperlane destination domain.
     * @param recipient Destination address on the remote chain.
     * @param amount Exact-out amount the recipient receives on the remote chain.
     * @param sender L2 originator (`msg.sender` of `sendNativeTokens`).
     * @param hypFee User-supplied Hyperlane dispatch-fee budget.
     * @param bridgeFee FluentBridge `sendMessage` fee charged at L2 dispatch time.
     */
    event NativeTransferInitiated(
        uint32 indexed domain,
        bytes32 indexed recipient,
        uint256 amount,
        address indexed sender,
        uint256 hypFee,
        uint256 bridgeFee
    );
}

/**
 * @title IL1HypNativeGateway
 * @dev L1 receive entrypoint for native ETH transfers; re-quotes and dispatches to Hyperlane.
 */
interface IL1HypNativeGateway is IHypNativeGatewayErrors, IHypNativeGatewayEvents {
    /**
     * @notice Bridge-only receive that re-quotes the configured warp route and dispatches.
     * @dev Tops up from the gateway's admin-funded native reserve when the live quote exceeds
     *      the bridge-transported value.
     */
    function receiveAndForwardNative(uint32 domain, bytes32 recipient, uint256 amount, address originSender) external payable;

    /**
     * @notice Admin: set the Hyperlane warp route address used by this gateway. Single
     *         source of truth — same address is the outbound dispatch target AND the
     *         authorized inbound caller (per design Q1: single shared multi-enrolled warp
     *         route on Ethereum).
     * @dev Zero address is rejected. The address must be a contract.
     */
    function setWarpRoute(address warpRoute) external;

    /**
     * @notice Returns the configured Hyperlane warp route, or `address(0)` if unset.
     */
    function getWarpRoute() external view returns (address);

    /**
     * @notice Admin: sweep native ETH off the gateway (reserve withdrawal, IGP refund sweep).
     */
    function rescueNative(address payable to, uint256 amount) external;

    /**
     * @notice Inbound entrypoint called by the configured warp route (`L1FluentHypNative`).
     *         Mirrors {NativeGateway-sendNativeTokens}: the warp route plays the role of the
     *         L1 sender; the gateway forwards `msg.value` and a `receiveNativeTokens`
     *         callback through {FluentBridge.sendMessage} to L2.
     * @dev `msg.value` is the entire native amount to deliver; no bridge fee on L1→L2
     *      (`FluentBridge.getSentMessageFee()` returns 0 on L1). Auth: `msg.sender` must
     *      equal {getWarpRoute}; reverts with {UnauthorizedWarpRoute} otherwise. Applies
     *      the outbound-blacklist check on `to`.
     * @param to L2 recipient that will receive ETH after the bridge relay.
     */
    function sendNativeTokens(address to) external payable;
}

/**
 * @title IL2HypNativeGateway
 * @dev L2 entrypoint for native ETH transfers routed through Hyperlane on L1.
 */
interface IL2HypNativeGateway is IHypNativeGatewayErrors, IHypNativeGatewayEvents {
    /**
     * @notice The user-specified `hypFee` is below the gateway's hardcoded minimum.
     */
    error InvalidHyperlaneFee(uint256 supplied, uint256 minimum);

    /**
     * @notice Bridges `amount` ETH to `recipient` on `domain` via Hyperlane on L1.
     * @param domain Hyperlane destination domain ID (NOT EVM chainId).
     * @param recipient Destination address on the remote chain (left-padded for EVM).
     * @param amount Exact-out: the recipient receives exactly `amount` on the destination chain.
     * @param hypFee User's pre-funded budget for the Hyperlane native dispatch fee.
     *
     * @dev Requires `msg.value >= amount + hypFee + bridgeFee`. Any excess joins the hypFee
     *      budget on L1 (covers drift between UI-quoting and execution; not refunded).
     */
    function sendNativeTokens(uint32 domain, bytes32 recipient, uint256 amount, uint256 hypFee) external payable;

    /**
     * @notice Admin: sweep native ETH off the gateway.
     * @dev EOAs may dust the gateway via `receive()`, and excess `msg.value` on `sendNativeTokens` is
     *      forwarded as cross-bridge value. This is the only path to recover funds stuck here.
     */
    function rescueNative(address payable to, uint256 amount) external;

    /**
     * @notice Bridge-only inbound entrypoint for native ETH delivered from the L1 gateway.
     *         Mirrors {NativeGateway-receiveNativeTokens} byte-for-byte in shape: bridge-only,
     *         peer-auth via {getOtherSideGateway}, `msg.value == amount`, blacklist on `to`,
     *         then forward ETH to `to` via low-level call. Emits {IGatewayBaseEvents-ReceivedTokens}.
     * @dev Note on the two "from" identities in this flow:
     *      - The bridge's `getNativeSender()` is the {L1HypNativeGateway} address (callsite
     *        of `FluentBridge.sendMessage`). Used for peer-auth against {getOtherSideGateway}.
     *      - The `from` parameter encoded in the payload is the warp route address
     *        (`L1FluentHypNative`) — the `msg.sender` of {sendNativeTokens} on L1. This is
     *        what the `ReceivedTokens` event indexes for off-chain correlation.
     *      Off-chain consumers correlate the Hyperlane origin domain via the L1 tx
     *      (canonical Hyperlane `ReceivedTransferRemote` event emitted by the warp route).
     * @param from Warp route address that originated the inbound forwarding on L1.
     * @param to L2 recipient.
     * @param amount Native ETH amount; MUST equal `msg.value`.
     */
    function receiveNativeTokens(address from, address to, uint256 amount) external payable;
}
