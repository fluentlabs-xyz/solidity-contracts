// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {Rollup} from "./rollup/Rollup.sol";
import {L2BlockHeader} from "./interfaces/IRollupTypes.sol";
import {Queue} from "./libraries/Queue.sol";
import {MerkleTree} from "./libraries/MerkleTree.sol";
import {ExcessivelySafeCall} from "./libraries/ExcessivelySafeCall.sol";

import {IFluentBridge} from "./interfaces/IFluentBridge.sol";
import {IL1BlockOracle} from "./interfaces/IL1BlockOracle.sol";

/**
 * @title FluentBridge
 * @author Fluent Labs
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
contract FluentBridge is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    IFluentBridge
{
    /// @notice Configuration for the FluentBridge initialization.
    struct InitConfiguration {
        /// @notice Owner of the contract (e.g. multisig or deployer).
        address initialOwner;
        /// @notice Address authorized to send authorized messages (usually a trusted relayer or bridge controller).
        address bridgeAuthority;
        /// @notice Address of the rollup contract.
        address rollup;
        /// @notice Number of blocks after which a message becomes eligible for rollback.
        uint256 receiveMessageDeadline;
        /// @notice Address of the bridge contract on the other chain.
        address otherBridge;
        /// @notice Address for L1 block number lookups
        address l1BlockOracle;
    }

    /// @custom:storage-location erc7201:fluent.storage.FluentBridgeStorage
    struct FluentBridgeStorage {
        uint256 nonce;
        uint256 receivedNonce;
        uint256 receiveMessageDeadline;
        address nativeSender;
        address otherBridge;
        mapping(bytes32 => MessageStatus) receivedMessage;
        mapping(bytes32 => MessageStatus) rollbackMessage;
        /// @dev deposit queue
        Queue.QueueStorage sentMessageQueue;
        address bridgeAuthority;
        address rollup;
        address l1BlockOracle;
        uint256[50] __gap;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.FluentBridgeStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FLUENT_BRIDGE_STORAGE_LOCATION = 0xe2e0b7768cb35928615964d328c094191301065845ac8cd8ffc433ff2eae9300;
    /// @dev returns the storage pointer for the FluentBridgeStorage struct.
    function _getFluentBridgeStorage() private pure returns (FluentBridgeStorage storage $) {
        assembly {
            $.slot := FLUENT_BRIDGE_STORAGE_LOCATION
        }
    }

    /// @dev Restricts function to be called only by the rollup contract.
    modifier onlyRollup() {
        require(msg.sender == _getFluentBridgeStorage().rollup, OnlyRollupAuthority());
        _;
    }

    /// @dev Restricts function to be called only by the bridge authority(bridge relayer)
    modifier onlyBridgeAuthority() {
        require(msg.sender == _getFluentBridgeStorage().bridgeAuthority, OnlyBridgeAuthority());
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the upgradeable bridge (replaces constructor when used behind a proxy).
     * @param data Configuration data encoded as InitConfiguration struct.
     * * - initialOwner: Owner of the contract (e.g. multisig or deployer).
     * * - bridgeAuthority: Address authorized to send authorized messages (usually a trusted relayer or bridge controller).
     * * - rollup: Address of the rollup contract.
     * * - receiveMessageDeadline: Number of blocks after which a message becomes eligible for rollback.
     * * - otherBridge: Address of the bridge contract on the other chain.
     * * - l1BlockOracle: Address for L1 block number lookups
     */
    function initialize(bytes calldata data) external initializer {
        InitConfiguration memory params = abi.decode(data, (InitConfiguration));

        /// the requirement of initialOwner not being address(0) exists in the __Ownable_init()
        __Ownable_init(params.initialOwner);
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        __FluentBridge_init(params);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @inheritdoc IFluentBridge
    function sendMessage(address to, bytes calldata message) external payable whenNotPaused {
        require(to != address(this) && to != otherBridge(), InvalidDestinationAddress());

        address from = msg.sender;
        uint256 value = msg.value;
        uint256 messageNonce = _takeNextNonce();
        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, block.chainid, block.number, messageNonce, message));

        /// @custom:todo remove 'if' later on when rollup is always initialized!!!!!!
        if (rollup() != address(0)) Queue.enqueue(_getFluentBridgeStorage().sentMessageQueue, messageHash);

        emit SentMessage(from, to, value, block.chainid, block.number, messageNonce, messageHash, message);
    }

    /// @inheritdoc IFluentBridge
    // TODO(d1r1, chillhacker): discuss the finalization and delivery flow:
    // 1. Batch finalization — permissionless, anyone can call tryFinalizeBatch() or
    //    finalizeEligibleBatches(). All batches from lastFinalizedBatchIndex+1 up to
    //    the target must be sequentially finalized. Each requires either the challenge
    //    period to pass without disputes, or all challenges resolved with valid proofs.
    // 2. Message delivery — after batch is finalized, _receiveMessage applies an
    //    additional L2-side deadline check (receiveMessageDeadline). If the message
    //    is too old relative to current L1 block, it is auto-declined without refund.
    //    This means a message can be finalized on L1 but still rejected on L2 — is
    //    this the intended behavior? Should we refund in this case?
    // 3. Consider whether these checks should be unified or documented more explicitly
    //    for callers — currently the failure modes are spread across multiple layers.
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
        require(rollup() != address(0), OnlyWhenRollupInited());
        // Batch must be finalized before withdrawal. Finalization is permissionless —
        // anyone can call tryFinalizeBatch() or finalizeEligibleBatches() on the rollup.
        require(Rollup(rollup()).tryFinalizeBatch(batchIndex), InvalidBlockProof()); // wake-disable-line reentrancy
        require(chainId != block.chainid, ForbiddenReceiveRollbackedMessage());
        require(msg.value == value, InvalidMessageValue(value, msg.value));

        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, chainId, blockNumber, messageNonce, message));
        require(receivedMessage(messageHash) == MessageStatus.None, MessageAlreadyReceived());

        _verifyWithdrawal(batchIndex, blockHeader, withdrawalProof, blockProof, messageHash);
        _receiveMessage(from, to, value, chainId, blockNumber, messageNonce, message, messageHash);
    }

    /// @inheritdoc IFluentBridge
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
        require(rollup() != address(0), OnlyWhenRollupInited());
        require(chainId != block.chainid, ForbiddenRollbackReceivedMessage());
        require(msg.value == 0, InvalidMessageValue(0, msg.value));

        if (value > 0) require(address(this).balance >= value, InsufficientBridgeBalance(value));
        // False positive: nonReentrant guard prevents re-entry; rollup is a trusted admin-set contract
        require(Rollup(rollup()).tryFinalizeBatch(batchIndex), InvalidBlockProof()); // wake-disable-line reentrancy

        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, chainId, blockNumber, messageNonce, message));
        require(receivedMessage(messageHash) == MessageStatus.None, MessageAlreadyReceived());

        _verifyWithdrawal(batchIndex, blockHeader, rollbackProof, blockProof, messageHash);
        _rollbackMessage(from, to, value, blockNumber, messageNonce, message, messageHash);
    }

    /// @inheritdoc IFluentBridge
    function receiveMessage(
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 messageNonce,
        bytes calldata message
    ) external payable onlyBridgeAuthority nonReentrant whenNotPaused {
        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, chainId, blockNumber, messageNonce, message));
        require(receivedMessage(messageHash) == MessageStatus.None, MessageAlreadyReceived());

        _receiveMessage(from, to, value, chainId, blockNumber, messageNonce, message, messageHash);
    }

    /// @inheritdoc IFluentBridge
    function receiveFailedMessage(
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 messageNonce,
        bytes calldata message
    ) external payable onlyBridgeAuthority nonReentrant whenNotPaused {
        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, chainId, blockNumber, messageNonce, message));
        require(receivedMessage(messageHash) == MessageStatus.Failed, MessageNotFailed());

        _receiveMessage(from, to, value, chainId, blockNumber, messageNonce, message, messageHash);
    }

    // ============ Internal functions ============

    function _receiveMessage(
        address _from,
        address _to,
        uint256 _value,
        uint256 /* _chainId */,
        uint256 _blockNumber,
        uint256 /* _nonce */,
        bytes calldata _message,
        bytes32 _messageHash
    ) internal {
        FluentBridgeStorage storage $ = _getFluentBridgeStorage();

        require(_to != address(this), ForbiddenSelfCall());
        /// @dev L2 related logic
        if ($.receiveMessageDeadline != 0) {
            if ($.l1BlockOracle == address(0)) {
                emit RollbackMessage(_messageHash, block.number);
                emit ReceivedMessage(_messageHash, false, "");
                return;
            } else {
                uint256 l1BlockNumber = IL1BlockOracle($.l1BlockOracle).getL1BlockNumber();
                if (l1BlockNumber >= _blockNumber && l1BlockNumber - _blockNumber >= $.receiveMessageDeadline) {
                    emit RollbackMessage(_messageHash, block.number);
                    emit ReceivedMessage(_messageHash, false, "");
                    return;
                }
            }
        }

        // if ($.receiveMessageDeadline != 0) {
        //     uint256 l1BlockNumber = IL1BlockOracle($.l1BlockOracle).getL1BlockNumber();
        //     if (_blockNumber + $.receiveMessageDeadline < l1BlockNumber) {
        //         emit RollbackMessage(_messageHash, block.number);
        //         emit ReceivedMessage(_messageHash, true, "");
        //         return;
        //     }
        // }

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
    ) internal {
        require(_to != address(this), ForbiddenSelfCall());

        (bool success, bytes memory data) = ExcessivelySafeCall.excessivelySafeCall(_from, _value, "");
        _getFluentBridgeStorage().rollbackMessage[_messageHash] = success ? MessageStatus.Success : MessageStatus.Failed;

        emit ReceivedMessageRollback(_messageHash, success, data);
    }

    function _verifyWithdrawal(
        uint256 _batchIndex,
        L2BlockHeader calldata _blockHeader,
        MerkleTree.MerkleProof calldata _withdrawalProof,
        MerkleTree.MerkleProof calldata _blockProof,
        bytes32 _messageHash
    ) internal view {
        bool blockValid = MerkleTree.verifyMerkleProof(
            Rollup(rollup()).getBatch(_batchIndex).batchRoot,
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

    function _takeNextNonce() internal returns (uint256) {
        return _getFluentBridgeStorage().nonce++;
    }

    function _takeNextReceivedNonce() internal returns (uint256) {
        return _getFluentBridgeStorage().receivedNonce++;
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

    // ============ Public view functions ============

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

    /// @inheritdoc IFluentBridge
    function sentMessageQueueSize() public view returns (uint256) {
        FluentBridgeStorage storage $ = _getFluentBridgeStorage();
        return Queue.size($.sentMessageQueue);
    }

    /// @inheritdoc IFluentBridge
    function popSentMessage() public onlyRollup returns (bytes32, uint256) {
        Queue.QueueItem memory item = Queue.dequeue(_getFluentBridgeStorage().sentMessageQueue);
        return (item.value, item.blockNumber);
    }

    // ============ Pauser functions ============

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Admin functions ============

    function setOtherBridge(address newOtherBridge) external onlyOwner {
        _setOtherBridge(newOtherBridge);
    }

    function _setOtherBridge(address _otherBridge) internal {
        require(_otherBridge != address(0), ZeroAddressNotAllowed("otherBridge"));
        emit OtherBridgeUpdated(_getFluentBridgeStorage().otherBridge, _otherBridge);
        _getFluentBridgeStorage().otherBridge = _otherBridge;
    }

    function setBridgeAuthority(address newBridgeAuthority) external onlyOwner {
        _setBridgeAuthority(newBridgeAuthority);
    }

    function _setBridgeAuthority(address _bridgeAuthority) internal {
        require(_bridgeAuthority != address(0), ZeroAddressNotAllowed("bridgeAuthority"));
        emit BridgeAuthorityUpdated(_getFluentBridgeStorage().bridgeAuthority, _bridgeAuthority);
        _getFluentBridgeStorage().bridgeAuthority = _bridgeAuthority;
    }

    /**
     * @notice Sets the address of the rollup contract from the owner.
     * @param newRollup The address of the rollup contract.
     * @dev This function can only be called by the owner.
     */
    function setRollup(address newRollup) external onlyOwner {
        _setRollup(newRollup);
    }

    function _setRollup(address _rollup) internal {
        if (_rollup == address(0)) require(sentMessageQueueSize() == 0, QueueNotEmpty());
        emit RollupUpdated(_getFluentBridgeStorage().rollup, _rollup);
        _getFluentBridgeStorage().rollup = _rollup;
    }

    /**
     * @notice Sets the address of the L1 block oracle.
     * @param newL1BlockOracle The address of the L1 block oracle used for rollback deadline checks.
     * @dev This function can only be called by the owner.
     */
    function setL1BlockOracle(address newL1BlockOracle) external onlyOwner {
        _setL1BlockOracle(newL1BlockOracle);
    }

    function _setL1BlockOracle(address _l1BlockOracle) internal {
        if (receiveMessageDeadline() != 0) require(_l1BlockOracle != address(0), ZeroAddressNotAllowed("l1BlockOracle"));
        emit L1BlockOracleUpdated(l1BlockOracle(), _l1BlockOracle);
        _getFluentBridgeStorage().l1BlockOracle = _l1BlockOracle;
    }

    /**
     * @notice Sets the number of L1 blocks after which a message becomes eligible for rollback.
     * @param newReceiveMessageDeadline The number of L1 blocks after which a message becomes eligible for rollback.
     * @dev This function can only be called by the owner.
     */
    function setReceiveMessageDeadline(uint256 newReceiveMessageDeadline) external onlyOwner {
        _setReceiveMessageDeadline(newReceiveMessageDeadline);
    }

    function _setReceiveMessageDeadline(uint256 _receiveMessageDeadline) internal {
        require(_receiveMessageDeadline != 0, ZeroValueNotAllowed("receiveMessageDeadline"));
        emit ReceiveMessageDeadlineUpdated(receiveMessageDeadline(), _receiveMessageDeadline);
        _getFluentBridgeStorage().receiveMessageDeadline = _receiveMessageDeadline;
    }

    // ============ Configuration ============

    function __FluentBridge_init(InitConfiguration memory params) internal {
        require(params.bridgeAuthority != address(0), ZeroAddressNotAllowed("bridgeAuthority"));
        require(params.otherBridge != address(0), ZeroAddressNotAllowed("otherBridge"));
        if (params.receiveMessageDeadline != 0) {
            require(params.l1BlockOracle != address(0), ZeroAddressNotAllowed("l1BlockOracle"));
        }

        _setBridgeAuthority(params.bridgeAuthority);
        _setOtherBridge(params.otherBridge);

        if (params.receiveMessageDeadline != 0) {
            _setReceiveMessageDeadline(params.receiveMessageDeadline);
            _setL1BlockOracle(params.l1BlockOracle);
        }

        if (params.rollup != address(0)) {
            _setRollup(params.rollup);
            Queue.initialize(_getFluentBridgeStorage().sentMessageQueue);
        }
    }
}
