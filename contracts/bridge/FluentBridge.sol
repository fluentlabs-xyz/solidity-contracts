// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ExcessivelySafeCall} from "../libraries/ExcessivelySafeCall.sol";

import {IFluentBridge} from "../interfaces/bridge/IFluentBridge.sol";

import {FluentBridgeStorageLayout} from "./FluentBridgeStorageLayout.sol";

/**
 * @title FluentBridge
 * @author Fluent Labs
 *
 * @notice Core bridge contract for sending and receiving cross-chain messages between L1 and L2 using rollup validation.
 * @dev Deployed on both L1 and L2 with different config (L1: rollup set, deadline 0; L2: rollup zero, deadline non-zero).
 *      Upgradeable via UUPS proxy (ERC1967Proxy); upgrade authorized by owner.
 *      Native token handling: on send, msg.value is locked in this contract; on receive, caller must supply msg.value
 *      equal to message value (relayer liquidity); on rollback, this contract refunds from its locked balance (msg.value must be 0).
 * @notice Workflows:
 * 1. Send message (L1 -> L2 or L2 -> L1):
 *    - Caller invokes sendMessage(to, message) with optional msg.value (native lock).
 *    - Message is encoded, hashed, and enqueued in the sent message queue when rollup is set.
 *    - Event SentMessage(from, to, value, chainId, blockNumber, nonce, messageHash, data) is emitted.
 * 2. Receive message with proof (L2 -> L1 only, when rollup is set):
 *    - Caller invokes receiveMessageWithProof(batchIndex, commitment, from, to, value, chainId, blockNumber, nonce, message, withdrawalProof, blockProof)
 *      with msg.value == value (caller supplies native for destination payout).
 *    - Withdrawal and block Merkle proofs are verified; message is executed (target receives value and calldata).
 *    - Event ReceivedMessage(messageHash, success, returnData) is emitted.
 * 3. Receive message by authority (L2 side or Trusted Relayer/Bridge Authority):
 *    - Bridge Authority invokes receiveMessage(from, to, value, chainId, blockNumber, nonce, message) with msg.value == value.
 *    - Sequential receivedNonce is enforced; message is executed.
 * 4. Rollback message (L2 -> L1, deadline exceeded):
 *    - Bridge Authority invokes rollbackMessageWithProof(...) with msg.value == 0.
 *    - This contract must hold at least `value` (locked from original send); refund is sent to original sender.
 *    - Event ReceivedMessageRollback(messageHash, success, returnData) is emitted.
 * 5. Replay failed message (Bridge Authority):
 *    - Bridge Authority invokes receiveFailedMessage(...) with msg.value == value for a message previously marked Failed.
 *    - Allows retrying after fixing conditions (e.g. gateway config).
 */
abstract contract FluentBridge is FluentBridgeStorageLayout {
    /**
     * @notice Sends a cross-chain message with optional native value.
     * @dev Deducts the L2 send fee (if any), encodes and hashes the message,
     *      then calls {_afterSendMessage} for chain-specific hooks (L1 enqueue).
     */
    function sendMessage(address to, bytes calldata message) external payable whenNotPaused nonReentrant {
        require(to != address(this) && to != getOtherBridge(), InvalidDestinationAddress());
        require(msg.value >= getSentMessageFee(), InsufficientFee());

        address from = msg.sender;
        uint256 value = msg.value - _chargeSendFee();
        uint256 messageNonce = _takeNextNonce();
        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, block.chainid, block.number, messageNonce, message));

        _afterSendMessage(messageHash);

        emit SentMessage(from, to, value, block.chainid, block.number, messageNonce, messageHash, message);
    }

    /**
     * @dev Hook for L2 to charge a message fee before the cross-chain value is encoded.
     *      Returns the fee amount deducted from `msg.value`. Base returns 0 (L1 has no fee).
     */
    function _chargeSendFee() internal virtual returns (uint256) {
        return 0;
    }

    /**
     * @dev Hook called after message encoding. L1 overrides to enqueue the message hash.
     */
    function _afterSendMessage(bytes32 messageHash) internal virtual {}

    /**
     * @notice Receives and executes a relayer-delivered cross-chain message.
     * @dev Enforces sequential nonce, verifies message not already processed,
     *      then delegates to {_receiveMessage} for ExcessivelySafeCall execution.
     */
    function receiveMessage(
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 messageNonce,
        bytes calldata message
    ) external onlyRole(RELAYER_ROLE) nonReentrant whenNotPaused {
        require(messageNonce == _takeNextReceivedNonce(), MessageReceivedOutOfOrder());
        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, chainId, blockNumber, messageNonce, message));
        require(getReceivedMessage(messageHash) == IFluentBridge.MessageStatus.None, MessageAlreadyReceived());

        require(to != address(this), ForbiddenSelfCall());
        if (!_beforeReceiveMessage(from, to, value, chainId, blockNumber, messageNonce, message)) return;

        _receiveMessage(getExecuteGasLimit(), from, to, value, message, messageHash);
    }

    /**
     * @notice Retries a previously failed message. Anyone can call with the original params.
     * @dev Requires message status == Failed. Uses full gasleft() instead of executeGasLimit.
     */
    function receiveFailedMessage(
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 messageNonce,
        bytes calldata message
    ) external payable nonReentrant whenNotPaused {
        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, chainId, blockNumber, messageNonce, message));
        require(getReceivedMessage(messageHash) == IFluentBridge.MessageStatus.Failed, MessageNotFailed());

        require(to != address(this), ForbiddenSelfCall());
        if (!_beforeReceiveMessage(from, to, value, chainId, blockNumber, messageNonce, message)) return;

        _receiveMessage(gasleft(), from, to, value, message, messageHash);
    }

    /**
     * @dev Hook called before message execution. Override in L1/L2 bridges for
     *      chain-specific checks (e.g., rollback deadline on L2). Return false to skip execution.
     */
    function _beforeReceiveMessage(
        address /* _from */,
        address /* _to */,
        uint256 /* _value */,
        uint256 /* _chainId */,
        uint256 /* _blockNumber */,
        uint256 /* _messageNonce */,
        bytes calldata /* _message */
    ) internal virtual returns (bool) {
        return true;
    }

    /**
     * @dev Core message execution: sets {_nativeSender} for cross-chain sender identification,
     *      forwards value and calldata via {ExcessivelySafeCall}, records result status.
     */
    function _receiveMessage(uint256 gasLimit, address from, address to, uint256 value, bytes calldata message, bytes32 messageHash) internal {
        FluentBridgeStorage storage $ = _getFluentBridgeStorage();

        $._nativeSender = from;
        (bool success, bytes memory data) = ExcessivelySafeCall.excessivelySafeCall(to, value, message, gasLimit);
        $._nativeSender = address(0);

        $._receivedMessage[messageHash] = success ? IFluentBridge.MessageStatus.Success : IFluentBridge.MessageStatus.Failed;
        emit ReceivedMessage(messageHash, success, data);
    }

    // ============ Pauser functions ============

    /**
     * @notice Pauses all bridge operations.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses bridge operations.
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
