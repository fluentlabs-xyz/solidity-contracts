// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {GatewayBase} from "./GatewayBase.sol";
import {FluentBridge} from "../bridge/FluentBridge.sol";

import {IL2HypNativeGateway, IL1HypNativeGateway} from "../interfaces/gateways/IHypNativeGateway.sol";

/**
 * @title L2HypNativeGateway
 * @author Fluent Labs
 *
 * @notice L2 entrypoint that bridges native ETH to a remote chain via Hyperlane on L1.
 * @dev UUPS-upgradeable. Inherits routing and blacklist machinery from {GatewayBase}.
 *      Encodes the Hyperlane parameters (destination domain, recipient, exact-out amount,
 *      and the user's native dispatch-fee budget) into a cross-chain message addressed to
 *      {L1HypNativeGateway}, and forwards it via {FluentBridge.sendMessage}.
 *
 *      `msg.value` must be at least `amount + hypFee + bridgeFee`:
 *      - `amount` — what the recipient receives on the destination chain (exact-out).
 *      - `hypFee` — pre-funded native budget the L1 gateway has available for the live
 *                   `quoteTransferRemote` at delivery time.
 *      - `bridgeFee` — {FluentBridge.getSentMessageFee} for cross-bridge delivery.
 *      Any excess (`msg.value - required`) is carried to L1 and joins the dispatch-fee
 *      reserve there; it is NOT refunded to the user.
 */
contract L2HypNativeGateway is GatewayBase, IL2HypNativeGateway {
    /// @notice Hard minimum on the user-supplied Hyperlane dispatch-fee budget.
    /// @dev Sanity floor only — actual live quote on L1 may exceed it, in which case the
    ///      L1 gateway tops up from its admin-funded reserve.
    uint256 public constant MIN_HYP_FEE_NATIVE = 0.001 ether;

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

    /// @inheritdoc IL2HypNativeGateway
    function sendNativeTokens(uint32 domain, bytes32 recipient, uint256 amount, uint256 hypFee) external payable nonReentrant {
        require(domain != 0, InvalidTargetDomain());
        require(recipient != bytes32(0), ZeroRecipient());
        require(hypFee >= MIN_HYP_FEE_NATIVE, InvalidHyperlaneFee(hypFee, MIN_HYP_FEE_NATIVE));

        address sender = msg.sender;
        _requireAccountNotBlacklisted(sender);
        _requireAccountNotBlacklisted(recipient);

        FluentBridge bridge = FluentBridge(getBridgeContract());

        // Mirror what the bridge itself will charge inside `sendMessage` so `required` matches
        // the actual deduction.
        uint256 bridgeFee = bridge.getSentMessageFee();
        // TODO(d1r1): bridgeFee under-pays the relayer here (L1 receive ~500k vs global default).
        // Resolve once FluentBridge exposes a per-gateway fee read.
        uint256 required = amount + bridgeFee + hypFee;
        require(msg.value >= required, InvalidNativeAmount(msg.value, required));

        bridge.sendMessage{value: msg.value}(
            getOtherSideGateway(),
            abi.encodeCall(IL1HypNativeGateway.receiveAndForwardNative, (domain, recipient, amount, sender))
        );

        emit NativeTransferInitiated(domain, recipient, amount, sender, hypFee, bridgeFee);
    }

    /// @inheritdoc IL2HypNativeGateway
    function receiveNativeTokens(address from, address to, uint256 amount) external payable onlyFluentBridge nonReentrant {
        // Peer-auth: only the configured L1 gateway (single peer for both outbound and
        // inbound) can deliver. Mirrors {NativeGateway-receiveNativeTokens:67}.
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(msg.value == amount, InvalidNativeAmount(msg.value, amount));
        require(to != address(0), InvalidRecipient());
        _requireAccountNotBlacklisted(to);

        // Forward ETH to recipient. Gas is bounded by the bridge's executeGasLimit on first
        // delivery, and by the caller's transaction gas on retry via receiveFailedMessage.
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, NativeTransferFailed());

        emit ReceivedTokens(from, to, amount);
    }

    /// @inheritdoc IL2HypNativeGateway
    function rescueNative(address payable to, uint256 amount) external nonReentrant onlyOwner {
        require(to != address(0), InvalidRecipient());
        (bool success, ) = to.call{value: amount}("");
        require(success, RescueFailed());
    }

    /// @dev Accepts admin-funded ETH refills and incidental returns. Funds are paid out
    ///      either as bridgeable payload value via `sendMessage{value: ...}` in
    ///      {sendNativeTokens} (outbound) or to L2 recipients in {receiveNativeTokens} (inbound,
    ///      paid from `msg.value` carried by the bridge, not from this balance).
    receive() external payable {}
}
