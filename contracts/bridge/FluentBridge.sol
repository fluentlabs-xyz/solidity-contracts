// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ExcessivelySafeCall} from "../libraries/ExcessivelySafeCall.sol";

import {IFluentBridge, IFluentBridgeWrite} from "../interfaces/bridge/IFluentBridge.sol";

import {FluentBridgeStorageLayout} from "./FluentBridgeStorageLayout.sol";

/**
 * @title FluentBridge
 * @author Fluent Labs
 *
 * @notice Core bridge contract for sending and receiving cross-chain messages between L1 and L2 using rollup validation.
 * @dev Deployed on both L1 and L2 with different config. L1 snapshots the receive-message
 *      deadline into outbound L1->L2 messages, while L2 validates the committed expiry
 *      against the L1 block oracle.
 *      Upgradeable via UUPS proxy (ERC1967Proxy); upgrade authorized by owner.
 *      Native token handling: on send, msg.value is locked in this contract; on receive and rollback,
 *      the bridge pays from its own pooled balance (receive functions are not payable).
 * @notice Workflows:
 * 1. Send message (L1 -> L2 or L2 -> L1):
 *    - Caller invokes sendMessage(to, message) with optional msg.value (native lock).
 *    - Message is encoded, hashed, and enqueued in the sent message queue when rollup is set.
 *    - Event SentMessage(from, to, value, chainId, validUntilBlockNumber, nonce, messageHash, data) is emitted.
 * 2. Receive message with proof (L2 -> L1 only, when rollup is set):
 *    - Caller invokes receiveMessageWithProof(...) — not payable, bridge pays value from pooled balance.
 *    - Withdrawal and block Merkle proofs are verified; message is executed (target receives value and calldata).
 *    - Event ReceivedMessage(messageHash, success, returnData) is emitted.
 * 3. Receive message by authority (L2 side or Trusted Relayer/Bridge Authority):
 *    - Bridge Authority invokes receiveMessage(...) — not payable, bridge pays value from pooled balance.
 *    - Sequential receivedNonce is enforced; message is executed.
 * 4. Rollback message (L2 -> L1, deadline exceeded):
 *    - Caller invokes rollbackMessageWithProof(...) — not payable, bridge refunds from locked balance.
 *    - Event ReceivedMessageRollback(messageHash, success, returnData) is emitted.
 * 5. Replay failed message:
 *    - Anyone invokes receiveFailedMessage(...) — not payable, bridge pays value from pooled balance.
 *    - Allows retrying after fixing conditions (e.g. gateway config).
 */
abstract contract FluentBridge is FluentBridgeStorageLayout, IFluentBridgeWrite {
    /// @inheritdoc IFluentBridgeWrite
    function sendMessage(address to, bytes calldata message) external payable virtual whenNotPaused nonReentrant {
        require(to != address(this) && to != getOtherBridge(), InvalidDestinationAddress());
        _beforeSendMessage(to, message);
        uint256 fee = getSentMessageFee();
        require(msg.value >= fee, InsufficientFee());

        address from = msg.sender;
        uint256 value = msg.value - fee;
        // Snapshot all message parameters before fee collection because the L2 fee transfer
        // performs an external call to the treasury. This keeps treasury callbacks from
        // observing or influencing pre-snapshot message state.
        uint256 messageNonce = _takeNextNonce();
        uint256 receiveMessageDeadline = _getReceiveMessageDeadline();
        uint256 validUntilBlockNumber = receiveMessageDeadline == 0 ? 0 : block.number + receiveMessageDeadline;
        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, block.chainid, validUntilBlockNumber, messageNonce, message));

        _chargeSendFee(fee);
        _afterSendMessage(messageHash);

        emit SentMessage(from, to, value, fee, block.chainid, validUntilBlockNumber, messageNonce, messageHash, message);
    }

    /**
     * @dev Hook for L2 to charge the already-computed `fee` after the outbound message has
     *      been snapshotted. Base is a no-op (L1 has no fee). The base deliberately passes
     *      the fee through instead of having the override re-fetch it from the oracle, so
     *      the transfer uses the exact value that `sendMessage` used to compute `value`.
     */
    function _chargeSendFee(uint256 /* fee */) internal virtual {}

    /**
     * @dev Hook called before message encoding. Override in L1/L2 bridges to add chain-specific
     *      pre-send checks by reverting with a specific error. Base is a no-op.
     *      Unlike {_beforeReceiveMessage} (which may silently skip an already-delivered message),
     *      this hook has no silent-skip path: on the send path the caller has paid no fee yet
     *      and nothing is recorded, so any failure MUST revert so the user sees it and no
     *      `msg.value` is silently accepted.
     */
    function _beforeSendMessage(address /** to */, bytes calldata /** message */) internal view virtual {}

    /**
     * @dev Hook called after message encoding. L1 overrides to enqueue the message hash.
     */
    function _afterSendMessage(bytes32 messageHash) internal virtual {}

    /// @inheritdoc IFluentBridgeWrite
    function receiveMessage(
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 validUntilBlockNumber,
        uint256 messageNonce,
        bytes calldata message
    ) external virtual onlyRole(RELAYER_ROLE) nonReentrant whenNotPaused {
        require(messageNonce == _takeNextReceivedNonce(), MessageReceivedOutOfOrder());
        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, chainId, validUntilBlockNumber, messageNonce, message));
        require(getReceivedMessage(messageHash) == IFluentBridge.MessageStatus.None, MessageAlreadyReceived());

        require(to != address(this), ForbiddenSelfCall());
        if (!_beforeReceiveMessage(from, to, value, chainId, validUntilBlockNumber, messageNonce, message)) {
            emit ReceivedMessage(messageHash, false, "");
            return;
        }

        (bool success, bytes memory data) = _receiveMessage(getExecuteGasLimit(), from, to, value, message, messageHash);
        emit ReceivedMessage(messageHash, success, data);
    }

    /// @inheritdoc IFluentBridgeWrite
    function receiveFailedMessage(
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 validUntilBlockNumber,
        uint256 messageNonce,
        bytes calldata message
    ) external nonReentrant whenNotPaused {
        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, chainId, validUntilBlockNumber, messageNonce, message));
        require(getReceivedMessage(messageHash) == IFluentBridge.MessageStatus.Failed, MessageNotFailed());

        require(to != address(this), ForbiddenSelfCall());
        if (!_beforeReceiveMessage(from, to, value, chainId, validUntilBlockNumber, messageNonce, message)) {
            emit RetriedFailedMessage(messageHash, false, "");
            return;
        }

        (bool success, bytes memory data) = _receiveMessage(gasleft(), from, to, value, message, messageHash);
        emit RetriedFailedMessage(messageHash, success, data);
    }

    /**
     * @dev Hook called before message execution. Override in L1/L2 bridges for
     *      chain-specific checks (e.g., committed expiry validation on L2). Return false to skip execution.
     */
    function _beforeReceiveMessage(
        address /* _from */,
        address /* _to */,
        uint256 /* _value */,
        uint256 /* _chainId */,
        uint256 /* _validUntilBlockNumber */,
        uint256 /* _messageNonce */,
        bytes calldata /* _message */
    ) internal virtual returns (bool) {
        return true;
    }

    /**
     * @dev Core message execution: sets {_nativeSender} for cross-chain sender identification,
     *      forwards value and calldata via {ExcessivelySafeCall}, records result status.
     */
    function _receiveMessage(
        uint256 gasLimit,
        address from,
        address to,
        uint256 value,
        bytes calldata message,
        bytes32 messageHash
    ) internal returns (bool success, bytes memory data) {
        FluentBridgeStorage storage $ = _getFluentBridgeStorage();

        $._nativeSender = from;
        (success, data) = ExcessivelySafeCall.excessivelySafeCall(to, value, message, gasLimit);
        $._nativeSender = address(0);

        $._receivedMessage[messageHash] = success ? IFluentBridge.MessageStatus.Success : IFluentBridge.MessageStatus.Failed;
        return (success, data);
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
