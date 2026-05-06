// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {GatewayBase} from "./GatewayBase.sol";
import {FluentBridge} from "../bridge/FluentBridge.sol";

import {INativeGateway} from "../interfaces/gateways/INativeGateway.sol";

/**
 * @title NativeGateway
 * @author Fluent Labs
 *
 * @notice Gateway for bridging native ETH between chains through `FluentBridge`.
 * @dev UUPS-upgradeable gateway. Bridge routing state is inherited from `GatewayBase` (ERC-7201 namespace).
 * @dev Security model:
 *      - `sendNativeTokens` requires `msg.value == amount`.
 *      - `receiveNativeTokens` is restricted to the configured bridge and verifies the remote gateway sender.
 *      - Incoming bridge calls must provide `msg.value == amount`, then ETH is forwarded to the recipient.
 * @dev Gas protection: the bridge's `executeGasLimit` caps gas for the entire message execution on first
 *      delivery. On retry via `receiveFailedMessage`, the caller controls gas via their transaction limit.
 *      No gateway-level gas cap is needed.
 * @dev Flows:
 *      1) Source chain: user calls `sendNativeTokens(to, amount)` and ETH is forwarded into
 *         `FluentBridge.sendMessage{value: ...}(otherSide, payload)` after a gateway blacklist check.
 *      2) Destination chain: relayer executes bridge delivery; gateway validates origin and transfers ETH to `to`.
 * @dev Admin functions: `rescueNative`.
 */
contract NativeGateway is GatewayBase, INativeGateway {
    /// @dev Shared-key slot for native-asset limit config in GatewayBase storage.
    address public constant NATIVE_LIMIT_KEY = address(0x0000012345678901234567890123456789012345);

    // ============ Constructor ============

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

    function sendNativeTokens(address to) external payable nonReentrant {
        require(to != address(0), InvalidRecipient());
        address sender = msg.sender;
        _requireAccountNotBlacklisted(sender);
        _requireAccountNotBlacklisted(to);

        // deduct the bridge relay fee; remainder is the actual bridged amount
        uint256 fee = FluentBridge(getBridgeContract()).getSentMessageFee();
        require(msg.value > fee, InvalidNativeAmount());
        uint256 amount = msg.value - fee;

        // forward full msg.value (amount + fee) so the bridge can retain the fee portion
        FluentBridge(getBridgeContract()).sendMessage{value: msg.value}(
            getOtherSideGateway(),
            abi.encodeCall(NativeGateway.receiveNativeTokens, (sender, to, amount))
        );
    }

    /// @inheritdoc INativeGateway
    function receiveNativeTokens(address from, address to, uint256 amount) external payable onlyFluentBridge nonReentrant {
        // verify the cross-chain message originated from the trusted remote gateway
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(msg.value == amount, InvalidNativeAmount());
        require(to != address(0), InvalidRecipient());

        // Whitelist / hourly / daily quota applies only while the source batch is still
        // Preconfirmed. Once the originating batch is Finalized the call is unrestricted.
        // No-op when the whitelist is disabled.
        _consumeLimit(NATIVE_LIMIT_KEY, amount);

        // Forward ETH to recipient — gas is bounded by the bridge's executeGasLimit on first
        // delivery, and by the caller's transaction gas limit on retry via receiveFailedMessage
        (bool success, ) = payable(to).call{value: amount}("");
        require(success, NativeTransferFailed());

        emit ReceivedTokens(from, to, amount);
    }

    /// @inheritdoc INativeGateway
    function rescueNative(address payable to, uint256 amount) external nonReentrant onlyOwner {
        require(to != address(0), InvalidRecipient());
        (bool success, ) = to.call{value: amount}("");
        require(success, NativeTransferFailed());
    }

    /**
     * @dev Accepts bare ETH transfers so the gateway can hold native value for bridging.
     */
    receive() external payable {}
}
