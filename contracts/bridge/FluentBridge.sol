// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {Queue} from "../libraries/Queue.sol";
import {MerkleTree} from "../libraries/MerkleTree.sol";
import {ExcessivelySafeCall} from "../libraries/ExcessivelySafeCall.sol";

import {IFluentBridge} from "../interfaces/bridge/IFluentBridge.sol";

import {FluentBridgeStorageLayout} from "./FluentBridgeStorageLayout.sol";

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
abstract contract FluentBridge is FluentBridgeStorageLayout {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the upgradeable bridge (replaces constructor when used behind a proxy).
     * @param data Configuration data encoded as InitConfiguration struct.
     * * - adminRole: Address authorized to perform admin actions.
     * * - pauserRole: Address authorized to pause the contract.
     * * - relayerRole: Address authorized to send authorized messages (a trusted relayer or bridge controller).
     * * - otherBridge: Address of the bridge contract on the other chain.
     */

    /// @inheritdoc IFluentBridge
    function sendMessage(address to, bytes calldata message) external payable whenNotPaused {
        require(to != address(this) && to != getOtherBridge(), InvalidDestinationAddress());

        address from = msg.sender;
        uint256 value = msg.value;
        uint256 messageNonce = _takeNextNonce();
        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, block.chainid, block.number, messageNonce, message));

        _afterSendMessage(from, to, value, block.chainid, block.number, messageNonce, message);

        emit SentMessage(from, to, value, block.chainid, block.number, messageNonce, messageHash, message);
    }

    /// @dev Virtual function that can be overridden by child contracts: L1_FluentBridge and L2_FluentBridge
    function _afterSendMessage(
        address _from,
        address _to,
        uint256 _value,
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _messageNonce,
        bytes calldata _message
    ) internal virtual {}

    /// @inheritdoc IFluentBridge
    function receiveMessage(
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 messageNonce,
        bytes calldata message
    ) external onlyRole(RELAYER_ROLE) nonReentrant whenNotPaused {
        // if it's L2 -> we mint EHH internally, it's supposed to be on the bridge
        // on L1 -> we don't mint EHH, it's supposed to be on the bridge -> we unlock it
        require(messageNonce == _takeNextReceivedNonce(), MessageReceivedOutOfOrder());
        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, chainId, blockNumber, messageNonce, message));
        require(getReceivedMessage(messageHash) == IFluentBridge.MessageStatus.None, MessageAlreadyReceived());

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
    ) external nonReentrant whenNotPaused {
        require(msg.value == value, InvalidMessageValue(value, msg.value));
        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, chainId, blockNumber, messageNonce, message));
        require(getReceivedMessage(messageHash) == IFluentBridge.MessageStatus.Failed, MessageNotFailed());

        _receiveMessage(from, to, value, chainId, blockNumber, messageNonce, message, messageHash);
    }

    /// @dev Virtual function that can be overridden by child contracts: L1_FluentBridge and L2_FluentBridge
    function _beforeReceiveMessage(
        address _from,
        address _to,
        uint256 _value,
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _messageNonce,
        bytes calldata _message
    ) internal virtual returns (bool) {
        return true;
    }

    function _receiveMessage(
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 messageNonce,
        bytes calldata message,
        bytes32 messageHash
    ) internal {
        FluentBridgeStorage storage $ = _getFluentBridgeStorage();

        require(to != address(this), ForbiddenSelfCall());

        if (!_beforeReceiveMessage(from, to, value, chainId, blockNumber, messageNonce, message)) return;

        $._nativeSender = from;
        (bool success, bytes memory data) = ExcessivelySafeCall.excessivelySafeCall(to, value, message, 50_000);
        $._nativeSender = address(0);

        $._receivedMessage[messageHash] = success ? IFluentBridge.MessageStatus.Success : IFluentBridge.MessageStatus.Failed;
        emit ReceivedMessage(messageHash, success, data);
    }

    // ============ Pauser functions ============

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
