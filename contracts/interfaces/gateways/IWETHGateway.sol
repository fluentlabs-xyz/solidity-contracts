// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title IWETHGatewayErrors
 * @dev Custom errors for the WETH bridging gateway.
 */
interface IWETHGatewayErrors {
    /**
     * @notice Thrown when `msg.value` on a bridge-delivered receive does not equal the
     *         `amount` field encoded in the message payload.
     * @dev Mirrors {INativeGatewayErrors.InvalidNativeAmount} — the WETH gateway transports
     *      value as native ETH across the bridge, so the same invariant applies.
     */
    error InvalidNativeAmount();

    /**
     * @notice Thrown when the gateway's ETH balance does not grow by exactly `amount`
     *         after calling `IWETH.withdraw(amount)`. A well-behaved WETH9 must return
     *         native value 1:1; anything else points at a misconfigured WETH address.
     */
    error UnwrapAccountingMismatch();

    /**
     * @notice Thrown when the gateway's WETH balance does not grow by exactly `amount`
     *         after calling `IWETH.deposit{value: amount}()`. Same 1:1 invariant as
     *         {UnwrapAccountingMismatch} but on the wrap leg.
     */
    error WrapAccountingMismatch();

    /**
     * @notice Thrown when recipient token balance does not increase by exactly `amount`
     *         after the gateway transfers wrapped tokens on receive.
     * @dev Defends against fee-on-transfer / non-canonical token behavior that would
     *      silently short-change the recipient.
     */
    error TransferAccountingMismatch();

    /**
     * @notice Thrown when a low-level native ETH transfer (rescue path) fails.
     */
    error NativeTransferFailed();

    /**
     * @notice Thrown when {getWETH} is still unset — {initialize} was called with a zero
     *         WETH address (two-phase bootstrap) and {setWETH} has not been called yet.
     */
    error WETHNotConfigured();
}

/**
 * @title IWETHGatewayEvents
 * @dev Events emitted by the WETH gateway on top of the shared {IGatewayBaseEvents} set.
 */
interface IWETHGatewayEvents {
    /**
     * @notice Emitted when the configured WETH contract is updated.
     */
    event WETHUpdated(address indexed prevValue, address indexed newValue);
}

/**
 * @title IWETHGateway
 * @author Fluent Labs
 *
 * @notice Bridges canonical WETH between chains by unwrapping on the source side,
 *         transporting native ETH via {FluentBridge}, and re-wrapping into the remote
 *         chain's canonical WETH on delivery. Users always see WETH in and WETH out.
 */
interface IWETHGateway is IWETHGatewayErrors, IWETHGatewayEvents {
    /**
     * @notice Returns the canonical WETH token this gateway wraps/unwraps against.
     */
    function getWETH() external view returns (address);

    /**
     * @notice Sets / updates the canonical WETH contract this gateway wraps/unwraps against.
     *
     * @dev Owner-only. Intended for the two-phase bootstrap where {initialize} was called
     *      with `wethContract = address(0)` so the gateway's proxy address is known before
     *      the CREATE2 Universal-WETH deploy on L2, and {setWETH} wires it afterwards.
     *      Reverts with {ZeroAddressNotAllowed} if `newWETH` is the zero address.
     *
     * @param newWETH Canonical WETH address on this chain (WETH9-compatible `deposit`/`withdraw`).
     */
    function setWETH(address newWETH) external;

    /**
     * @notice Bridges `amount` of this chain's WETH to `to` on the other chain, where it
     *         will be delivered as the remote chain's canonical WETH.
     *
     * @dev The caller must have approved the gateway to spend `amount` WETH beforehand.
     *      The bridge fee is paid separately as `msg.value` (must equal
     *      `FluentBridge.getSentMessageFee()` — same semantics as {IERC20Gateway.sendTokens}).
     *
     * @param to Recipient address on the remote chain (must be non-zero).
     * @param amount Amount of WETH to bridge (must be non-zero).
     */
    function sendWETH(address to, uint256 amount) external payable;

    /**
     * @notice Bridge-delivered counterpart of {sendWETH}. Wraps `msg.value` into the local
     *         canonical WETH and forwards it to `to`.
     *
     * @dev Restricted to the configured {FluentBridge}. The original cross-chain sender
     *      must be the configured remote gateway; otherwise the call reverts with
     *      {IGatewayBaseErrors.MessageFromWrongGateway} and the bridge marks the message
     *      {MessageStatus.Failed}.
     *
     * @param from Original sender on the remote chain (for event emission only).
     * @param to Final recipient of the wrapped WETH on this chain.
     * @param amount Amount of WETH to mint to `to`. Must equal `msg.value`.
     */
    function receiveWETH(address from, address to, uint256 amount) external payable;
}
