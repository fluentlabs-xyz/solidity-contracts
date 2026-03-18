// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {FluentBridge} from "../FluentBridge.sol";
import {Rollup} from "../../rollup/Rollup.sol";

import {MerkleTree} from "../../libraries/MerkleTree.sol";
import {Queue} from "../../libraries/Queue.sol";
import {ExcessivelySafeCall} from "../../libraries/ExcessivelySafeCall.sol";

import {L2BlockHeader} from "../../interfaces/IRollupTypes.sol";
import {IFluentBridge} from "../../interfaces/bridge/IFluentBridge.sol";
import {IL1_FluentBridge} from "../../interfaces/bridge/IL1_FluentBridge.sol";

/**
 * @title L1_FluentBridge
 * @author Fluent Labs
 * @dev L1 bridge contract for the Fluent bridge.
 */
contract L1_FluentBridge is FluentBridge, IL1_FluentBridge {
    /**
     * @notice Status of a rollback execution by message hash.
     */
    mapping(bytes32 => IFluentBridge.MessageStatus) internal _rollbackMessages;

    Rollup internal _rollup;

    /**
     * @notice Queue of sent messages.
     */
    Queue.QueueStorage _sentMessageQueue;
    /**
     * @notice Gap for future storage.
     */
    uint256[50] __gap;

    /**
     * @dev Restricts function to be called only by the rollup contract.
     */
    modifier onlyRollup() {
        require(msg.sender == getRollup(), OnlyRollup());
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(bytes calldata data, address newRollup) external initializer {
        __ReentrancyGuard_init();
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        __FluentBridgeStorage_init(data);

        _setRollup(newRollup);
        Queue.initialize(_sentMessageQueue);
    }

    function _afterSendMessage(
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 messageNonce,
        bytes calldata message
    ) internal override {
        Queue.enqueue(_sentMessageQueue, keccak256(_encodeMessage(from, to, value, chainId, blockNumber, messageNonce, message)));
    }

    /// @inheritdoc IFluentBridge
    function receiveMessageWithProof(
        uint256 batchIndex,
        L2BlockHeader calldata blockHeader,
        address from,
        address payable to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 messageNonce,
        bytes calldata message,
        MerkleTree.MerkleProof calldata withdrawalProof,
        MerkleTree.MerkleProof calldata blockProof
    ) external payable nonReentrant whenNotPaused {
        // Batch must be finalized before withdrawal. Call rollup.finalizeBatches() first.
        require(_rollup.isBatchFinalized(batchIndex), InvalidBlockProof()); // wake-disable-line reentrancy
        require(chainId != block.chainid, ForbiddenReceiveRollbackMessage());
        require(msg.value == value, InvalidMessageValue(value, msg.value));

        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, chainId, blockNumber, messageNonce, message));
        require(getReceivedMessage(messageHash) == IFluentBridge.MessageStatus.None, MessageAlreadyReceived());

        _verifyWithdrawal(batchIndex, blockHeader, withdrawalProof, blockProof, messageHash);
        _receiveMessage(from, to, value, chainId, blockNumber, messageNonce, message, messageHash);
    }

    /// @inheritdoc IFluentBridge
    /// @dev should live on the bridge on L1
    function rollbackMessageWithProof(
        uint256 batchIndex,
        L2BlockHeader calldata blockHeader,
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 messageNonce,
        bytes calldata message,
        MerkleTree.MerkleProof calldata rollbackProof,
        MerkleTree.MerkleProof calldata blockProof
    ) external payable nonReentrant whenNotPaused {
        require(chainId != block.chainid, ForbiddenRollbackReceivedMessage());

        if (value > 0) require(address(this).balance >= value, InsufficientBridgeBalance(value));

        // Batch must be finalized before rollback. Call rollup.finalizeBatches() first.
        require(Rollup(_rollup).isBatchFinalized(batchIndex), InvalidBlockProof()); // wake-disable-line reentrancy

        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, chainId, blockNumber, messageNonce, message));
        require(getReceivedMessage(messageHash) == IFluentBridge.MessageStatus.None, MessageAlreadyReceived());
        require(getRollbackMessage(messageHash) == IFluentBridge.MessageStatus.None, MessageAlreadyReceived());

        _verifyWithdrawal(batchIndex, blockHeader, rollbackProof, blockProof, messageHash);
        _rollbackMessage(from, to, value, blockNumber, messageNonce, message, messageHash);
    }

    function _verifyWithdrawal(
        uint256 _batchIndex,
        L2BlockHeader calldata _blockHeader,
        MerkleTree.MerkleProof calldata _withdrawalProof,
        MerkleTree.MerkleProof calldata _blockProof,
        bytes32 _messageHash
    ) internal view {
        bool blockValid = MerkleTree.verifyMerkleProof(
            Rollup(_rollup).getBatch(_batchIndex).batchRoot,
            keccak256(
                abi.encodePacked(_blockHeader.previousBlockHash, _blockHeader.blockHash, _blockHeader.withdrawalRoot, _blockHeader.depositRoot)
            ),
            _blockProof.nonce,
            _blockProof.proof
        );
        require(blockValid, InvalidBlockProof());

        bool withdrawalValid = MerkleTree.verifyMerkleProof(
            _blockHeader.withdrawalRoot,
            _messageHash,
            _withdrawalProof.nonce,
            _withdrawalProof.proof
        );
        require(withdrawalValid, InvalidWithdrawalProof());
    }

    function _rollbackMessage(
        address from,
        address to,
        uint256 value,
        uint256 blockNumber,
        uint256 messageNonce,
        bytes calldata message,
        bytes32 messageHash
    ) internal {
        require(to != address(this), ForbiddenSelfCall());

        (bool success, bytes memory data) = ExcessivelySafeCall.excessivelySafeCall(from, value, "", 50_000);
        _rollbackMessages[messageHash] = success ? IFluentBridge.MessageStatus.Success : IFluentBridge.MessageStatus.Failed;

        emit ReceivedMessageRollback(messageHash, success, data);
    }

    /// @inheritdoc IFluentBridge
    function popSentMessage() public onlyRollup returns (bytes32, uint256) {
        Queue.QueueItem memory item = Queue.dequeue(_sentMessageQueue);
        return (item.value, item.blockNumber);
    }

    function getRollbackMessage(bytes32 key) public view returns (IFluentBridge.MessageStatus) {
        return _rollbackMessages[key];
    }

    /// @inheritdoc IL1_FluentBridge
    function getRollup() public view returns (address) {
        return address(_rollup);
    }

    /// @inheritdoc IL1_FluentBridge
    function setRollup(address newRollup) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRollup(newRollup);
    }

    function _setRollup(address newRollup) internal {
        require(newRollup != address(0), ZeroAddressNotAllowed("rollup"));
        require(Queue.size(_sentMessageQueue) == 0, QueueNotEmpty());
        _rollup = Rollup(newRollup);
        emit RollupUpdated(getRollup(), newRollup);
    }
}
