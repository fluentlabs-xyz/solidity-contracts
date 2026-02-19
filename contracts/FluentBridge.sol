// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {Rollup} from "./rollup/Rollup.sol";
import {Queue} from "./libraries/Queue.sol";
import {MerkleTree} from "./libraries/MerkleTree.sol";
import {ExcessivelySafeCall} from "./libraries/ExcessivelySafeCall.sol";

import {IFluentBridge} from "./interfaces/IFluentBridge.sol";
import {IL1BlockOracle} from "./interfaces/IL1BlockOracle.sol";

/**
 * @title FluentBridge
 * @author Fluent Labs
 * @notice A contract that handles sending and receiving cross-chain messages between L1 and L2 using rollup validation.
 * @dev This contract is deployed on both L1 and L2, with different configurations on each side.
 *      It supports message rollback logic in case messages are not processed within a deadline.
 *      Upgradeable via transparent proxy (TransparentUpgradeableProxy + ProxyAdmin).
 * @notice Workflows:
 * 1. Send message from L1 to L2:
 *    - User sends message to FluentBridge.sendMessage(to, message)
 *    - Message is encoded and hashed
 *    - Message is enqueued in the sent message queue
 *    - Event SentMessage is emitted
 * 2. Receive message from L2 to L1:
 *    - User sends message to FluentBridge.receiveMessage(from, to, value, chainId, blockNumber, nonce, message)
 *    - Message is encoded and hashed
 *    - Message is verified and executed
 *    - Event ReceivedMessage is emitted
 * 3. Rollback message from L2 to L1:
 *    - User sends message to FluentBridge.rollbackMessageWithProof(...)
 *    - Message is encoded and hashed
 *    - Message is verified and executed
 *    - Event ReceivedMessageRollback is emitted
 * 4. Receive failed message:
 *    - User sends message to FluentBridge.receiveFailedMessage(...)
 *    - Event ReceivedMessageFailed is emitted
 */
contract FluentBridge is IFluentBridge, Initializable, ReentrancyGuardUpgradeable, Ownable2StepUpgradeable, PausableUpgradeable {
    /// @custom:storage-location erc7201:fluent.storage.FluentBridgeStorage
    struct FluentBridgeStorage {
        uint256 nonce;
        uint256 receivedNonce;
        uint256 receiveMessageDeadline;
        address nativeSender;
        address otherBridge;
        mapping(bytes32 => MessageStatus) receivedMessage;
        mapping(bytes32 => MessageStatus) rollbackMessage;
        Queue.QueueStorage sentMessageQueue;
        address bridgeAuthority;
        address rollup;
        address l1BlockOracle;
        uint256[50] __gap;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.FluentBridgeStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FLUENT_BRIDGE_STORAGE_LOCATION = 0xe2e0b7768cb35928615964d328c094191301065845ac8cd8ffc433ff2eae9300;

    function _getFluentBridgeStorage() private pure returns (FluentBridgeStorage storage $) {
        assembly {
            $.slot := FLUENT_BRIDGE_STORAGE_LOCATION
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Restricts function to be called only by the rollup contract.
    modifier onlyRollup() {
        require(msg.sender == _getFluentBridgeStorage().rollup, OnlyRollupAuthority());
        _;
    }

    /// @dev Restricts function to be called only by the bridge authority.
    modifier onlyBridgeSender() {
        require(msg.sender == _getFluentBridgeStorage().bridgeAuthority, OnlyBridgeAuthority());
        _;
    }

    /**
     * @notice Initializes the upgradeable bridge (replaces constructor when used behind a proxy).
     * @param _initialOwner Owner of the contract (e.g. multisig or deployer).
     * @param _bridgeAuthority Address permitted to send authorized messages (usually a trusted relayer or bridge controller).
     * @param _rollup Address of the rollup contract.
     *        - On L1: should be the actual Rollup contract address.
     *        - On L2: should be set to address(0), as rollup verification is not needed.
     * @param _receiveMessageDeadline Number of blocks after which a message becomes eligible for rollback.
     *        - On L2: should be set to a non-zero value to enable rollback after timeout.
     *        - On L1: should be set to 0, as rollback is not applicable.
     * @param _otherBridge Address of the Bridge contract on the other chain.
     * @param _l1BlockOracle Address for L1 block number lookups
     */
    function initialize(
        address _initialOwner,
        address _bridgeAuthority,
        address _rollup,
        uint256 _receiveMessageDeadline,
        address _otherBridge,
        address _l1BlockOracle
    ) external initializer {
        __ReentrancyGuard_init();
        __Ownable_init(_initialOwner);
        __Ownable2Step_init();
        __Pausable_init();

        FluentBridgeStorage storage $ = _getFluentBridgeStorage();
        $.bridgeAuthority = _bridgeAuthority;
        $.rollup = _rollup;
        $.receiveMessageDeadline = _receiveMessageDeadline;
        $.otherBridge = _otherBridge;
        $.l1BlockOracle = _l1BlockOracle;
        if ($.rollup != address(0)) {
            Queue.initialize($.sentMessageQueue);
        }
    }

    /**
     * @notice Sets the address of the Bridge contract on the other chain.
     * @param _otherBridge The address of the Bridge contract on the other chain.
     */
    /// @inheritdoc IFluentBridge
    function setOtherBridge(address _otherBridge) external onlyOwner {
        _getFluentBridgeStorage().otherBridge = _otherBridge;
    }

    /// @notice Returns the size of the sent message queue.
    /// @inheritdoc IFluentBridge
    function getQueueSize() external view returns (uint256) {
        FluentBridgeStorage storage $ = _getFluentBridgeStorage();
        if ($.rollup != address(0)) {
            return Queue.size($.sentMessageQueue);
        }
        return 0;
    }

    /// @notice Dequeues a message for rollup processing.
    /// @dev Callable only by the Rollup contract.
    /// @inheritdoc IFluentBridge
    function popSentMessage() public onlyRollup returns (bytes32) {
        return Queue.dequeue(_getFluentBridgeStorage().sentMessageQueue);
    }

    /**
     * @notice Sends a cross-chain message.
     * @param _to Destination address on target chain.
     * @param _message Arbitrary calldata payload to deliver.
     */
    function sendMessage(address _to, bytes calldata _message) external payable whenNotPaused {
        FluentBridgeStorage storage $ = _getFluentBridgeStorage();
        require(_to != address(this) && _to != $.otherBridge, InvalidDestinationAddress());

        address from = msg.sender;
        uint256 value = msg.value;
        uint256 messageNonce = _takeNextNonce();

        bytes memory encodedMessage = _encodeMessage(from, _to, value, block.chainid, block.number, messageNonce, _message);

        bytes32 messageHash = keccak256(encodedMessage);

        if ($.rollup != address(0)) {
            Queue.enqueue($.sentMessageQueue, messageHash);
        }

        emit SentMessage(from, _to, value, block.chainid, block.number, messageNonce, messageHash, _message);
    }

    /**
     * @notice Receives and executes a cross-chain message using Merkle proofs for verification.
     * @dev Can only be used on the **L1 side** to process messages originating from L2.
     */
    /// @inheritdoc IFluentBridge
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
    ) external payable nonReentrant whenNotPaused {
        FluentBridgeStorage storage $ = _getFluentBridgeStorage();
        require(Rollup($.rollup).ensureBatchApproved(_batchIndex), InvalidBlockProof());
        require(_chainId == block.chainid, ForbiddenReceiveRollbackedMessage());

        bytes32 messageHash = keccak256(_encodeMessage(_from, _to, _value, _chainId, _blockNumber, _nonce, _message));

        require($.receivedMessage[messageHash] == MessageStatus.None, MessageAlreadyReceived());

        _verifyWithdrawal(_batchIndex, _commitmentBatch, _withdrawal_proof, _block_proof, messageHash);

        _receiveMessage(_from, _to, _value, _chainId, _blockNumber, _nonce, _message, messageHash);
    }

    /**
     * @notice Processes a rollback message with accompanying Merkle proofs.
     * @dev Can only be used on the **L1 side** to refund the original sender when a message was not successfully received on L2.
     */
    /// @inheritdoc IFluentBridge
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
    ) external payable nonReentrant whenNotPaused {
        FluentBridgeStorage storage $ = _getFluentBridgeStorage();
        require($.rollup != address(0), OnlyWhenRollupInited());
        require(_chainId == block.chainid, ForbiddenRollbackReceivedMessage());
        require(Rollup($.rollup).ensureBatchApproved(_batchIndex), InvalidBlockProof());

        bytes32 messageHash = keccak256(_encodeMessage(_from, _to, _value, _chainId, _blockNumber, _nonce, _message));

        require($.receivedMessage[messageHash] == MessageStatus.None, MessageAlreadyReceived());

        _verifyWithdrawal(_batchIndex, _commitmentBatch, _rollback_proof, _block_proof, messageHash);
        _rollbackMessage(_from, _to, _value, _blockNumber, _nonce, _message, messageHash);
    }

    /**
     * @notice Receives and executes a cross-chain message sent directly by the trusted bridge authority.
     * @dev This method is used **only on the L2 side**, where messages are delivered by an off-chain relayer.
     */
    /// @inheritdoc IFluentBridge
    function receiveMessage(
        address _from,
        address _to,
        uint256 _value,
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _nonce,
        bytes calldata _message
    ) external payable onlyBridgeSender nonReentrant whenNotPaused {
        require(_nonce == _takeNextReceivedNonce(), MessageReceivedOutOfOrder());

        bytes memory encodedMessage = _encodeMessage(_from, _to, _value, _chainId, _blockNumber, _nonce, _message);
        bytes32 messageHash = keccak256(encodedMessage);

        require(_getFluentBridgeStorage().receivedMessage[messageHash] == MessageStatus.None, MessageAlreadyReceived());

        _receiveMessage(_from, _to, _value, _chainId, _blockNumber, _nonce, _message, messageHash);
    }

    /**
     * @notice Retries the execution of a previously failed cross-chain message.
     */
    /// @inheritdoc IFluentBridge
    function receiveFailedMessage(
        address _from,
        address _to,
        uint256 _value,
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _nonce,
        bytes calldata _message
    ) external payable nonReentrant whenNotPaused {
        bytes memory encodedMessage = _encodeMessage(_from, _to, _value, _chainId, _blockNumber, _nonce, _message);
        bytes32 messageHash = keccak256(encodedMessage);

        require(_getFluentBridgeStorage().receivedMessage[messageHash] == MessageStatus.Failed, MessageNotFailed());

        _receiveMessage(_from, _to, _value, _chainId, _blockNumber, _nonce, _message, messageHash);
    }

    // ---------- Public getters ----------

    /// @inheritdoc IFluentBridge
    function nonce() public view returns (uint256) {
        return _getFluentBridgeStorage().nonce;
    }

    /// @inheritdoc IFluentBridge
    function receivedNonce() public view returns (uint256) {
        return _getFluentBridgeStorage().receivedNonce;
    }

    /// @inheritdoc IFluentBridge
    function receiveMessageDeadline() public view returns (uint256) {
        return _getFluentBridgeStorage().receiveMessageDeadline;
    }

    /// @inheritdoc IFluentBridge
    function nativeSender() public view returns (address) {
        return _getFluentBridgeStorage().nativeSender;
    }

    /// @inheritdoc IFluentBridge
    function otherBridge() public view returns (address) {
        return _getFluentBridgeStorage().otherBridge;
    }

    /// @inheritdoc IFluentBridge
    function receivedMessage(bytes32 key) public view returns (MessageStatus) {
        return _getFluentBridgeStorage().receivedMessage[key];
    }

    /// @inheritdoc IFluentBridge
    function rollbackMessage(bytes32 key) public view returns (MessageStatus) {
        return _getFluentBridgeStorage().rollbackMessage[key];
    }

    /// @inheritdoc IFluentBridge
    function bridgeAuthority() public view returns (address) {
        return _getFluentBridgeStorage().bridgeAuthority;
    }

    /// @inheritdoc IFluentBridge
    function rollup() public view returns (address) {
        return _getFluentBridgeStorage().rollup;
    }

    /// @inheritdoc IFluentBridge
    function l1BlockOracle() public view returns (address) {
        return _getFluentBridgeStorage().l1BlockOracle;
    }

    function _receiveMessage(
        address _from,
        address _to,
        uint256 _value,
        uint256 /* _chainId */,
        uint256 _blockNumber,
        uint256 /* _nonce */,
        bytes calldata _message,
        bytes32 _messageHash
    ) private {
        require(_to != address(this), ForbiddenSelfCall());

        FluentBridgeStorage storage $ = _getFluentBridgeStorage();
        if ($.receiveMessageDeadline != 0) {
            uint256 l1BlockNumber = IL1BlockOracle($.l1BlockOracle).getL1BlockNumber();
            if (_blockNumber + $.receiveMessageDeadline < l1BlockNumber) {
                emit RollbackMessage(_messageHash, block.number);
                emit ReceivedMessage(_messageHash, true, "");
                return;
            }
        }

        $.nativeSender = _from;
        (bool success, bytes memory data) = ExcessivelySafeCall.excessivelySafeCall(_to, _value, _message);
        $.nativeSender = address(0);

        $.receivedMessage[_messageHash] = success ? MessageStatus.Success : MessageStatus.Failed;
        emit ReceivedMessage(_messageHash, success, data);
    }

    function _rollbackMessage(
        address _from,
        address _to,
        uint256 _value,
        uint256 /*_blockNumber*/,
        uint256 /*_nonce*/,
        bytes calldata /*_message*/,
        bytes32 _messageHash
    ) private {
        require(_to != address(this), ForbiddenSelfCall());

        (bool success, bytes memory data) = ExcessivelySafeCall.excessivelySafeCall(_from, _value, "");
        _getFluentBridgeStorage().rollbackMessage[_messageHash] = success ? MessageStatus.Success : MessageStatus.Failed;

        emit ReceivedMessageRollback(_messageHash, success, data);
    }

    function _verifyWithdrawal(
        uint256 _batchIndex,
        Rollup.BlockCommitment calldata _commitmentBatch,
        MerkleTree.MerkleProof calldata _withdrawal_proof,
        MerkleTree.MerkleProof calldata _block_proof,
        bytes32 _messageHash
    ) internal view {
        bool blockValid = MerkleTree.verifyMerkleProof(
            Rollup(rollup()).acceptedBatchHash(_batchIndex),
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
        require(blockValid, InvalidBlockProof());

        bool withdrawalValid = MerkleTree.verifyMerkleProof(
            _commitmentBatch.withdrawalHash,
            _messageHash,
            _withdrawal_proof.nonce,
            _withdrawal_proof.proof
        );
        require(withdrawalValid, InvalidWithdrawalProof());
    }

    function _takeNextNonce() internal returns (uint256) {
        FluentBridgeStorage storage $ = _getFluentBridgeStorage();
        return $.nonce++;
    }

    function _takeNextReceivedNonce() internal returns (uint256) {
        FluentBridgeStorage storage $ = _getFluentBridgeStorage();
        return $.receivedNonce++;
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
        return abi.encode(_from, _to, _value, _chainId, _blockNumber, _nonce, _message);
    }

    /**
     * @notice Pauses the contract, preventing all non-owner functions from being called
     * @dev Only callable by the owner
     */
    /// @inheritdoc IFluentBridge
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract, allowing all functions to be called again
     * @dev Only callable by the owner
     */
    /// @inheritdoc IFluentBridge
    function unpause() external onlyOwner {
        _unpause();
    }
}
