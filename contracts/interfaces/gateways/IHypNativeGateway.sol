// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title IHypNativeGatewayErrors
 * @dev Custom errors shared by the native ETH Hyperlane gateway pair.
 */
interface IHypNativeGatewayErrors {
    /**
     * @notice Forwarding to Hyperlane was attempted while the originating L1 batch is still
     *         in {BatchStatus.Preconfirmed}. Hyperlane dispatch is irreversible across the
     *         Fluent trust boundary, so the gateway only forwards once the source batch is
     *         finalized.
     */
    error CrossBoundaryRequiresFinalized();

    /**
     * @notice No warp route is configured for the requested Hyperlane destination domain.
     */
    error UnsupportedDomain(uint32 domain);

    /**
     * @notice The warp route returned a non-native fee token in one of the three quote entries.
     * @param quoteIndex Position in the `Quote[]` returned by `quoteTransferRemote` (0..2).
     * @param actualToken Non-native token address returned at that index.
     */
    error UnexpectedFeeToken(uint8 quoteIndex, address actualToken);

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
     * @dev `address(0)` is allowed (clears the route); anything else must have code.
     */
    error WarpRouteNotAContract(address warpRoute);

    /**
     * @notice The low-level call inside {rescueNative} returned `false`.
     */
    error RescueFailed();
}

/**
 * @title IHypNativeGatewayEvents
 * @dev Events emitted by the native ETH Hyperlane gateway pair.
 */
interface IHypNativeGatewayEvents {
    /**
     * @notice L1: per-domain warp route mapping changed. `next == address(0)` means unenrolled.
     */
    event WarpRouteUpdated(uint32 indexed domain, address indexed prev, address indexed next);

    /**
     * @notice L1: emitted after a successful `transferRemote` dispatch.
     * @param domain Hyperlane destination domain.
     * @param recipient Destination address on the remote chain (bytes32 — left-padded for EVM).
     * @param amount Exact-out amount delivered to the recipient on the destination chain.
     * @param originSender L2 `msg.sender` of the originating {IL2HypNativeGateway.sendNative} call;
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
     * @param sender L2 originator (`msg.sender` of `sendNative`).
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
     * @notice Admin: register or update the warp route for a Hyperlane destination domain.
     * @dev Passing `warpRoute == address(0)` unregisters the route for `domain`.
     */
    function setWarpRoute(uint32 domain, address warpRoute) external;

    /**
     * @notice Returns the currently configured warp route for `domain`, or `address(0)`.
     */
    function getWarpRoute(uint32 domain) external view returns (address);

    /**
     * @notice Admin: sweep native ETH off the gateway (reserve withdrawal, IGP refund sweep).
     */
    function rescueNative(address payable to, uint256 amount) external;
}

/**
 * @title IL2HypNativeGateway
 * @dev L2 entrypoint for native ETH transfers routed through Hyperlane on L1.
 */
interface IL2HypNativeGateway is IHypNativeGatewayErrors, IHypNativeGatewayEvents {
    /**
     * @notice `msg.value` is less than `amount + hypFee + bridgeFee`. UI underquoted the cost.
     */
    error InvalidNativeAmount(uint256 supplied, uint256 required);

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
    function sendNative(uint32 domain, bytes32 recipient, uint256 amount, uint256 hypFee) external payable;

    /**
     * @notice Admin: sweep native ETH off the gateway.
     * @dev EOAs may dust the gateway via `receive()`, and excess `msg.value` on `sendNative` is
     *      forwarded as cross-bridge value. This is the only path to recover funds stuck here.
     */
    function rescueNative(address payable to, uint256 amount) external;
}
