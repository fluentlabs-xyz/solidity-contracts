// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./libraries/Queue.sol";
import {IERC20Gateway} from "./interfaces/IERC20Gateway.sol";
import {MerkleTree} from "./libraries/MerkleTree.sol";
import {Rollup} from "./rollup/Rollup.sol";

/**
 * @title Bridge
 * @notice A contract that handles sending, receiving cross-chain messages between L1 and L2 using rollup validation.
 * @dev Works in conjunction with a Rollup contract and supports message rollback logic.
 */
/**
 * @title Bridge
 * @notice A contract that handles sending and receiving cross-chain messages between L1 and L2 using rollup validation.
 * @dev This contract is deployed on both L1 and L2, with different configurations on each side.
 *      It supports message rollback logic in case messages are not processed within a deadline.
 */
contract Bridge is ReentrancyGuard {
    uint256 public nonce;
    uint256 public receivedNonce;
    uint256 public receiveMessageDeadline;

    error OnlyBridgeAuthority();
    error OnlyRollupAuthority();
    error MessageAlreadyReceived();
    error MessageReceivedOutOfOrder();
    error MessageNotFailed();
    error ForbiddenSelfCall();
    error RollbackMessageMismatch();
    error InvalidBlockProof();
    error InvalidWithdrawalProof();

    /// @notice Enum describing status of a message: None, Failed, or Success.
    enum MessageStatus {
        None,
        Failed,
        Success
    }

    /// @notice Mapping of received message hashes to their status.
    mapping(bytes32 => MessageStatus) public receivedMessage;
    /// @notice Mapping of rollback message hashes to their rollback result status.
    mapping(bytes32 => MessageStatus) public rollbackMessage;

    /// @notice Queue of sent messages awaiting confirmation.
    /// @dev This is used only on the L1 side to track outbound messages for potential rollback.
    Queue.QueueStorage private sentMessageQueue;

    /// @notice Address authorized to send direct messages.
    address public bridgeAuthority;

    /// @notice The associated rollup contract.
    /// @dev Used only on the L1 side to verify batch approvals and validate Merkle proofs.
    address public rollup;

    /// @dev Restricts function to be called only by the rollup contract.
    modifier onlyRollup() {
        if (msg.sender != rollup) revert OnlyRollupAuthority();
        _;
    }

    /// @dev Restricts function to be called only by the bridge authority.
    modifier onlyBridgeSender() {
        if (msg.sender != bridgeAuthority) revert OnlyBridgeAuthority();
        _;
    }

    /// @notice Emitted when a message is sent to another chain.
    event SentMessage(
        address indexed sender,
        address indexed to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 nonce,
        bytes32 messageHash,
        bytes data
    );

    /// @notice Emitted after message is successfully received and executed.
    event ReceivedMessage(
        bytes32 messageHash,
        bool successfulCall,
        bytes returnData
    );

    /// @notice Emitted when a rollback message is triggered.
    event RollbackMessage(bytes32 messageHash, uint256 blockNumber);

    /// @notice Emitted after a rollback is executed.
    event ReceivedMessageRollback(
        bytes32 messageHash,
        bool successfulCall,
        bytes returnData
    );


    /**
     * @param _bridgeAuthority Address permitted to send authorized messages (usually a trusted relayer or bridge controller).
     * @param _rollup Address of the rollup contract.
     *        - On L1: should be the actual Rollup contract address.
     *        - On L2: should be set to address(0), as rollup verification is not needed.
     * @param _receiveMessageDeadline Number of blocks after which a message becomes eligible for rollback.
     *        - On L2: should be set to a non-zero value to enable rollback after timeout.
     *        - On L1: should be set to 0, as rollback is not applicable.
     */
    constructor(
        address _bridgeAuthority,
        address _rollup,
        uint256 _receiveMessageDeadline
    ) {
        bridgeAuthority = _bridgeAuthority;
        rollup = _rollup;
        receiveMessageDeadline = _receiveMessageDeadline;
        if (rollup != address(0)) {
            Queue.initialize(sentMessageQueue);
        }
    }

    /// @notice Returns the size of the sent message queue.
    function getQueueSize() external view returns (uint256) {
        if (rollup != address(0)) {
            return Queue.size(sentMessageQueue);
        }
        return 0;
    }


    /// @notice Dequeues a message for rollup processing.
    /// @dev Callable only by the Rollup contract.
    function popSentMessage() public onlyRollup returns (bytes32) {
        return Queue.dequeue(sentMessageQueue);
    }


    /**
     * @notice Sends a cross-chain message.
     * @param _to Destination address on target chain.
     * @param _message Arbitrary calldata payload to deliver.
     */
    function sendMessage(
        address _to,
        bytes calldata _message
    ) external payable {
        address from = msg.sender;
        uint256 value = msg.value;
        uint256 messageNonce = _takeNextNonce();

        bytes memory encodedMessage = _encodeMessage(
            from,
            _to,
            value,
            block.chainid,
            block.number,
            messageNonce,
            _message
        );

        bytes32 messageHash = keccak256(encodedMessage);

        if (rollup != address(0)) {
            Queue.enqueue(sentMessageQueue, messageHash);
        }

        emit SentMessage(
            from,
            _to,
            value,
            block.chainid,
            block.number,
            messageNonce,
            messageHash,
            _message
        );
    }

    /**
     * @notice Receives and executes a cross-chain message using Merkle proofs for verification.
     * @dev Can only be used on the **L1 side** to process messages originating from L2.
     *      To successfully call this function, the sender must prove:
     *      1. That the message hash is included in the withdrawal Merkle tree (via `_withdrawal_proof`).
     *      2. That the block commitment (which contains the withdrawal root) is included in the commitment batch (via `_block_proof`).
     *      3. That the commitment batch was previously accepted and approved in the rollup at `_batchIndex`.
     *
     * @param _batchIndex The index of the accepted rollup batch that contains the block commitment.
     * @param _commitmentBatch The block commitment that includes the withdrawal root.
     * @param _from The address that originally sent the message.
     * @param _to The address that should receive the message and value.
     * @param _value Amount of ETH to be sent along with the message.
     * @param _chainId The chain ID where the message was intended to be executed.
     * @param _blockNumber The L2 block number in which the message was originally sent.
     * @param _nonce The unique nonce associated with the message.
     * @param _message The calldata payload of the cross-chain message.
     * @param _withdrawal_proof Merkle proof showing the message is part of the withdrawal root in the commitment.
     * @param _block_proof Merkle proof showing the block commitment is part of the accepted batch at `_batchIndex`.
     */
    function receiveMessageWithProof(
        uint256 _batchIndex,
        Rollup.BlockCommitment calldata _commitmentBatch,
        address _from,
        address payable _to,
        uint256 _value,
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _nonce,
        bytes calldata _message,
        MerkleTree.MerkleProof calldata _withdrawal_proof,
        MerkleTree.MerkleProof calldata _block_proof
    ) external payable nonReentrant {
        if (_nonce != _takeNextReceivedNonce())
            revert MessageReceivedOutOfOrder();
        if (!Rollup(rollup).approvedBatch(_batchIndex))
            revert InvalidBlockProof();

        bytes32 messageHash = keccak256(
            _encodeMessage(
                _from,
                _to,
                _value,
                _chainId,
                _blockNumber,
                _nonce,
                _message
            )
        );

        if (receivedMessage[messageHash] != MessageStatus.None)
            revert MessageAlreadyReceived();

        _verifyWithdrawal(
            _batchIndex,
            _commitmentBatch,
            _withdrawal_proof,
            _block_proof,
            messageHash
        );
        _receiveMessage(
            _from,
            _to,
            _value,
            _chainId,
            _blockNumber,
            _nonce,
            _message,
            messageHash
        );
    }

    /**
     * @notice Processes a rollback message with accompanying Merkle proofs.
     * @dev Can only be used on the **L1 side** to refund the original sender when a message was not successfully received on L2.
     *      This is allowed only if the message was not executed on L2 within the `_receiveMessageDeadline` window.
     *      The message inclusion is proven in the same way as in the `receiveMessageWithProof` function — using:
     *      - A Merkle proof of the message in the withdrawal root
     *      - A Merkle proof of the block in the accepted rollup batch
     *
     * @param _batchIndex Index of the batch containing the message.
     * @param _commitmentBatch Commitment block that includes the withdrawal and deposit roots.
     * @param _from The original sender of the message.
     * @param _to The intended recipient (typically failed to receive).
     * @param _value The ETH value originally sent with the message.
     * @param _chainId The chain ID the message was intended for.
     * @param _blockNumber The original block number the message was sent in.
     * @param _nonce The unique nonce of the message.
     * @param _message The calldata payload of the message.
     * @param _rollback_proof Merkle proof that the message is included in the withdrawal root.
     * @param _block_proof Merkle proof that the commitment block is included in the accepted batch.
     */
    function rollbackMessageWithProof(
        uint256 _batchIndex,
        Rollup.BlockCommitment calldata _commitmentBatch,
        address _from,
        address _to,
        uint256 _value,
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _nonce,
        bytes calldata _message,
        MerkleTree.MerkleProof calldata _rollback_proof,
        MerkleTree.MerkleProof calldata _block_proof
    ) external payable nonReentrant {
        if (!Rollup(rollup).approvedBatch(_batchIndex))
            revert InvalidBlockProof();

        bytes32 messageHash = keccak256(
            _encodeMessage(
                _from,
                _to,
                _value,
                _chainId,
                _blockNumber,
                _nonce,
                _message
            )
        );

        if (receivedMessage[messageHash] != MessageStatus.None)
            revert MessageAlreadyReceived();

        _verifyWithdrawal(
            _batchIndex,
            _commitmentBatch,
            _rollback_proof,
            _block_proof,
            messageHash
        );
        _rollbackMessage(
            _from,
            _to,
            _value,
            _blockNumber,
            _nonce,
            _message,
            messageHash
        );
    }

    /**
     * @notice Receives and executes a cross-chain message sent directly by the trusted bridge authority.
     * @dev This method is used **only on the L2 side**, where messages are delivered by an off-chain relayer
     *      without requiring on-chain Merkle proof verification.
     *
     *      The relayer (bridge authority) is responsible for:
     *      - Fetching finalized messages from L1
     *      - Calling this function with the correct message parameters
     *      - Ensuring messages are received in strict nonce order
     *
     *      ❗ This method does not verify Merkle proofs directly, but correctness is guaranteed because:
     *      - The message must be included in the **deposit root** of a Rollup block commitment on L1
     *      - The Rollup contract validates the deposit root during `acceptNextBatch`
     *
     *      ⏳ This method **must be called before** `receiveMessageDeadline` blocks have passed
     *      since `_blockNumber`, otherwise the message becomes eligible for rollback on L1 using `rollbackMessageWithProof`.
     *
     * @param _from The original sender of the message on L1.
     * @param _to The recipient on L2.
     * @param _value Amount of ETH to send with the message.
     * @param _chainId The intended target chain ID.
     * @param _blockNumber The L1 block number when the message was sent.
     * @param _nonce The message nonce; must match the expected `receivedNonce`.
     * @param _message The calldata to execute on `_to`.
     *
     */
    function receiveMessage(
        address _from,
        address _to,
        uint256 _value,
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _nonce,
        bytes calldata _message
    ) external payable onlyBridgeSender nonReentrant {
        if (_nonce != _takeNextReceivedNonce())
            revert MessageReceivedOutOfOrder();

        bytes memory encodedMessage = _encodeMessage(
            _from,
            _to,
            _value,
            _chainId,
            _blockNumber,
            _nonce,
            _message
        );
        bytes32 messageHash = keccak256(encodedMessage);

        if (receivedMessage[messageHash] != MessageStatus.None)
            revert MessageAlreadyReceived();

        _receiveMessage(
            _from,
            _to,
            _value,
            _chainId,
            _blockNumber,
            _nonce,
            _message,
            messageHash
        );
    }

    /**
     * @notice Retries the execution of a previously failed cross-chain message.
     * @dev This method allows anyone to re-attempt delivering a message that was previously marked as `Failed`
     *      during execution (e.g., the target contract reverted or ran out of gas).
     *
     *      This function:
     *      - Requires no authority or Merkle proof
     *      - Is open to the public
     *      - Is only allowed for messages whose status is explicitly `MessageStatus.Failed`
     *      - Uses the same internal `_receiveMessage` logic
     *
     *      The message is identified by its encoded parameters and re-verified against the `receivedMessage` mapping.
     *
     * @param _from The original sender of the message on L1.
     * @param _to The intended recipient of the message on L2.
     * @param _value Amount of ETH to send with the call.
     * @param _chainId The chain ID where the message was intended to execute.
     * @param _blockNumber The L1 block number when the message was sent.
     * @param _nonce The unique message nonce.
     * @param _message The calldata payload to execute on `_to`.
     */
    function receiveFailedMessage(
        address _from,
        address _to,
        uint256 _value,
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _nonce,
        bytes calldata _message
    ) external payable nonReentrant {
        bytes memory encodedMessage = _encodeMessage(
            _from,
            _to,
            _value,
            _chainId,
            _blockNumber,
            _nonce,
            _message
        );
        bytes32 messageHash = keccak256(encodedMessage);

        if (receivedMessage[messageHash] != MessageStatus.Failed)
            revert MessageNotFailed();

        _receiveMessage(
            _from,
            _to,
            _value,
            _chainId,
            _blockNumber,
            _nonce,
            _message,
            messageHash
        );
    }

    /**
     * @dev Executes a received cross-chain message and records its result.
     *
     * This function is used internally by `receiveMessage`, `receiveMessageWithProof`, and `receiveFailedMessage`.
     *
     * It performs the following:
     * - Prevents execution if the target is the Bridge contract itself.
     * - Checks whether the message is still within the valid `receiveMessageDeadline` window.
     *   - If the deadline has expired, the message is **not executed** and is marked for potential rollback via `RollbackMessage` event.
     * - If still valid, executes the message using a low-level `.call{value: _value}` to `_to` with the provided payload.
     * - Stores the result (`Success` or `Failed`) in `receivedMessage`.
     * - Emits a `ReceivedMessage` event.
     *
     * If the message fails (e.g., due to target contract reversion):
     * - It is marked as `MessageStatus.Failed`.
     * - The user or relayer can later **retry** execution **without proofs or bridge authority** by calling `receiveFailedMessage`.
     *
     * @param _from The original sender of the message.
     * @param _to The target contract or recipient address.
     * @param _value The amount of ETH to send with the call.
     * @param _chainId The chain ID (used in message hashing/encoding).
     * @param _blockNumber The L1 block number when the message was sent.
     * @param _nonce The unique nonce associated with the message.
     * @param _message The calldata payload to be executed on `_to`.
     * @param _messageHash The keccak256 hash of the encoded message.
     */
    function _receiveMessage(
        address _from,
        address _to,
        uint256 _value,
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _nonce,
        bytes calldata _message,
        bytes32 _messageHash
    ) private {
        if (_to == address(this)) revert ForbiddenSelfCall();

        if (
            receiveMessageDeadline != 0 &&
            _blockNumber + receiveMessageDeadline < block.number
        ) {
            emit RollbackMessage(_messageHash, block.number);
            return;
        }

        (bool success, bytes memory data) = _to.call{value: _value}(_message);

        receivedMessage[_messageHash] = success
            ? MessageStatus.Success
            : MessageStatus.Failed;
        emit ReceivedMessage(_messageHash, success, data);
    }

    function _rollbackMessage(
        address _from,
        address _to,
        uint256 _value,
        uint256 _blockNumber,
        uint256 _nonce,
        bytes calldata _message,
        bytes32 _messageHash
    ) private {
        if (_to == address(this)) revert ForbiddenSelfCall();
        if (_messageHash != Queue.dequeue(sentMessageQueue))
            revert RollbackMessageMismatch();

        (bool success, bytes memory data) = _from.call{value: _value}("");
        rollbackMessage[_messageHash] = success
            ? MessageStatus.Success
            : MessageStatus.Failed;
        emit ReceivedMessageRollback(_messageHash, success, data);
    }

    function _verifyWithdrawal(
        uint256 _batchIndex,
        Rollup.BlockCommitment calldata _commitmentBatch,
        MerkleTree.MerkleProof calldata _withdrawal_proof,
        MerkleTree.MerkleProof calldata _block_proof,
        bytes32 _messageHash
    ) private {
        bool blockValid = MerkleTree.verifyMerkleProof(
            Rollup(rollup).acceptedBatchHash(_batchIndex),
            keccak256(
                abi.encodePacked(
                    _commitmentBatch.previousBlockHash,
                    _commitmentBatch.blockHash,
                    _commitmentBatch.withdrawalHash,
                    _commitmentBatch.depositHash
                )
            ),
            _block_proof.nonce,
            _block_proof.proof
        );
        if (!blockValid) revert InvalidBlockProof();

        bool withdrawalValid = MerkleTree.verifyMerkleProof(
            _commitmentBatch.withdrawalHash,
            _messageHash,
            _withdrawal_proof.nonce,
            _withdrawal_proof.proof
        );
        if (!withdrawalValid) revert InvalidWithdrawalProof();
    }


    function _takeNextNonce() internal returns (uint256) {
        return nonce++;
    }

    function _takeNextReceivedNonce() internal returns (uint256) {
        return receivedNonce++;
    }

    function _encodeMessage(
        address _from,
        address _to,
        uint256 _value,
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _nonce,
        bytes calldata _message
    ) internal pure returns (bytes memory) {
        return
            abi.encode(
                _from,
                _to,
                _value,
                _chainId,
                _blockNumber,
                _nonce,
                _message
            );
    }
}
