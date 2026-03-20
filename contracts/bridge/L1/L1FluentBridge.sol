// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {FluentBridge} from "../FluentBridge.sol";
import {Rollup} from "../../rollup/Rollup.sol";

import {MerkleTree} from "../../libraries/MerkleTree.sol";
import {Queue} from "../../libraries/Queue.sol";
import {ExcessivelySafeCall} from "../../libraries/ExcessivelySafeCall.sol";

import {L2BlockHeader} from "../../interfaces/IRollupTypes.sol";
import {IFluentBridge} from "../../interfaces/bridge/IFluentBridge.sol";
import {IL1FluentBridge} from "../../interfaces/bridge/IL1FluentBridge.sol";

/**
 * @title L1FluentBridge
 * @author Fluent Labs
 * @dev L1 bridge contract for the Fluent bridge.
 */
contract L1FluentBridge is FluentBridge, IL1FluentBridge {
    /**
     * @notice Status of a rollback execution by message hash.
     */
    mapping(bytes32 => IFluentBridge.MessageStatus) internal _rollbackMessages;
    /**
     * @notice Rollup contract.
     */
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

    /// @notice manual claim from L2 -> L1
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
    ) external nonReentrant whenNotPaused {
        // Batch must be finalized before withdrawal. Call rollup.finalizeBatches() first.
        require(_rollup.isBatchFinalized(batchIndex), InvalidBlockProof()); // wake-disable-line reentrancy
        require(chainId != block.chainid, ForbiddenReceiveRollbackMessage());

        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, chainId, blockNumber, messageNonce, message));
        require(getReceivedMessage(messageHash) == IFluentBridge.MessageStatus.None, MessageAlreadyReceived());

        _verifyWithdrawal(batchIndex, blockHeader, withdrawalProof, blockProof, messageHash);
        require(to != address(this), ForbiddenSelfCall());
        if (!_beforeReceiveMessage(from, to, value, chainId, blockNumber, messageNonce, message)) return;

        _receiveMessage(gasleft(), from, to, value, message, messageHash);
    }

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
        MerkleTree.MerkleProof calldata withdrawalProof,
        MerkleTree.MerkleProof calldata blockProof
    ) external nonReentrant whenNotPaused {
        // Batch must be finalized before rollback. Call rollup.finalizeBatches() first.
        require(Rollup(_rollup).isBatchFinalized(batchIndex), InvalidBlockProof()); // wake-disable-line reentrancy
        require(chainId != block.chainid, ForbiddenRollbackReceivedMessage());
        if (value > 0) require(address(this).balance >= value, InsufficientBridgeBalance(value));

        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, chainId, blockNumber, messageNonce, message));
        require(getReceivedMessage(messageHash) == IFluentBridge.MessageStatus.None, MessageAlreadyReceived());
        require(getRollbackMessage(messageHash) == IFluentBridge.MessageStatus.None, MessageAlreadyReceived());

        _verifyWithdrawal(batchIndex, blockHeader, withdrawalProof, blockProof, messageHash);
        _rollbackMessage(gasleft(), from, to, value, blockNumber, messageNonce, message, messageHash);
    }

    function _verifyWithdrawal(
        uint256 batchIndex,
        L2BlockHeader calldata blockHeader,
        MerkleTree.MerkleProof calldata withdrawalProof,
        MerkleTree.MerkleProof calldata blockProof,
        bytes32 messageHash
    ) internal view {
        bool blockValid = MerkleTree.verifyMerkleProof(
            Rollup(_rollup).getBatch(batchIndex).batchRoot,
            keccak256(
                abi.encodePacked(blockHeader.previousBlockHash, blockHeader.blockHash, blockHeader.withdrawalRoot, blockHeader.depositRoot)
            ),
            blockProof.nonce,
            blockProof.proof
        );
        require(blockValid, InvalidBlockProof());

        bool withdrawalValid = MerkleTree.verifyMerkleProof(
            blockHeader.withdrawalRoot,
            messageHash,
            withdrawalProof.nonce,
            withdrawalProof.proof
        );
        require(withdrawalValid, InvalidWithdrawalProof());
    }

    function _rollbackMessage(
        uint256 /*gasLimit*/,
        address from,
        address to,
        uint256 value,
        uint256 /*blockNumber*/,
        uint256 /*messageNonce*/,
        bytes calldata /*message*/,
        bytes32 messageHash
    ) internal {
        require(to != address(this), ForbiddenSelfCall());

        (bool success, bytes memory data) = ExcessivelySafeCall.excessivelySafeCall(from, value, "", 50_000);
        _rollbackMessages[messageHash] = success ? IFluentBridge.MessageStatus.Success : IFluentBridge.MessageStatus.Failed;

        emit ReceivedMessageRollback(messageHash, success, data);
    }

    function popSentMessage() public onlyRollup returns (bytes32, uint256) {
        Queue.QueueItem memory item = Queue.dequeue(_sentMessageQueue);
        return (item.value, item.blockNumber);
    }

    function getRollbackMessage(bytes32 key) public view returns (IFluentBridge.MessageStatus) {
        return _rollbackMessages[key];
    }

    /// @inheritdoc IL1FluentBridge
    function getRollup() public view returns (address) {
        return address(_rollup);
    }

    /// @inheritdoc IL1FluentBridge
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
