// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FluentBridge as Bridge} from "../../contracts/FluentBridge.sol";
import {IFluentBridge} from "../../contracts/interfaces/IFluentBridge.sol";
import {L1BlockOracle} from "../../contracts/oracle/L1BlockOracle.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {RollupStorageLayout} from "../../contracts/rollup/RollupStorageLayout.sol";
import {VerifierMock} from "../../contracts/mocks/VerifierMock.sol";
import {RollupBase, Vm} from "../Rollup/Base.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Receiver that increments a counter; used to verify deadline rollback path.
contract NoopReceiver {
    uint256 public calls;

    function handle() external payable {
        calls++;
    }
}

// Receiver that always reverts; used to drive MessageStatus.Failed.
contract RevertingReceiver {
    function fail() external payable {
        revert("revert-in-receiver");
    }
}

contract BridgeLegacyParityTest is RollupBase {
    address internal constant USER = address(0x1234);
    address internal constant DESTINATION = address(0x1111111111111111111111111111111111111111);
    address internal constant OTHER_BRIDGE = address(0x2222222222222222222222222222222222222222);
    address internal constant RECEIVER = address(0x4567);

    uint256 internal constant MSG_VALUE = 2000;
    bytes internal constant PAYLOAD = hex"0102030405";

    L1BlockOracle internal oracle;

    function setUp() public {
        verifierMock = new VerifierMock();
        Rollup rollupImpl = new Rollup();
        RollupStorageLayout.InitConfiguration memory initParams = RollupStorageLayout.InitConfiguration({
            admin: address(this),
            pauser: address(0),
            sequencer: SEQUENCER,
            challengeDepositAmount: 10000,
            challengeBlockCount: 0,
            approveBlockCount: 1,
            verifier: address(verifierMock),
            programVKey: MOCK_VK_KEY,
            genesisHash: MOCK_GENESIS_HASH,
            bridge: address(0x1),
            batchSize: 2,
            acceptDepositDeadline: 10,
            incentiveFee: 0,
            challenger: address(0),
            prover: address(0)
        });
        ERC1967Proxy rollupProxy = new ERC1967Proxy(
            address(rollupImpl),
            abi.encodeCall(Rollup.initialize, (abi.encode(initParams)))
        );
        rollup = Rollup(payable(address(rollupProxy)));
        oracle = new L1BlockOracle();

        Bridge bridgeImpl = new Bridge();
        ERC1967Proxy bridgeProxy = new ERC1967Proxy(
            address(bridgeImpl),
            abi.encodeCall(
                Bridge.initialize, (address(this), address(this), address(rollup), 10, OTHER_BRIDGE, address(oracle))
            )
        );
        bridge = Bridge(payable(address(bridgeProxy)));
        rollup.setBridge(address(bridge));
        rollup.setDaCheck(false);
    }

    function test_sendMessageAndAcceptBatch_reducesQueue() public {
        vm.deal(USER, 1 ether);

        uint256 msgNonce = bridge.nonce();
        uint256 msgBlock = block.number;
        bytes32 messageHash =
            _bridgeMessageHash(USER, DESTINATION, MSG_VALUE, block.chainid, msgBlock, msgNonce, PAYLOAD);

        vm.prank(USER);
        bridge.sendMessage{value: MSG_VALUE}(DESTINATION, PAYLOAD);

        assertEq(address(bridge).balance, MSG_VALUE, "bridge balance should include sent value");
        assertEq(bridge.sentMessageQueueSize(), 1, "queue should include the message");

        bytes32 blockHash1 = keccak256("bridge-send-block-1");
        bytes32 blockHash2 = keccak256("bridge-send-block-2");

        RollupStorageLayout.BlockCommitment[] memory batch = new RollupStorageLayout.BlockCommitment[](2);
        batch[0] = _buildCommitment(MOCK_GENESIS_HASH, blockHash1, ZERO_HASH, keccak256(abi.encodePacked(messageHash)));
        batch[1] = _buildCommitment(blockHash1, blockHash2, ZERO_HASH, ZERO_HASH);

        RollupStorageLayout.DepositsInBlock[] memory deposits = new RollupStorageLayout.DepositsInBlock[](1);
        deposits[0] = RollupStorageLayout.DepositsInBlock({blockHash: blockHash1, depositCount: 1});

        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(batch, deposits, 0);

        assertEq(bridge.sentMessageQueueSize(), 0, "queue should be consumed");
    }

    function test_receiveMessage_marksSuccessAndRejectsOutOfOrderNonce() public {
        vm.deal(address(this), 1 ether);

        uint256 nonce = bridge.receivedNonce();
        uint256 receiverBalanceBefore = RECEIVER.balance;
        uint256 sourceChainId = block.chainid + 1;
        uint256 sourceBlock = 10;

        bridge.receiveMessage{value: 200}(DESTINATION, RECEIVER, 200, sourceChainId, sourceBlock, nonce, "");

        uint256 receiverBalanceAfter = RECEIVER.balance;
        assertEq(receiverBalanceAfter - receiverBalanceBefore, 200, "receiver should be paid");

        bytes32 messageHash = _bridgeMessageHash(DESTINATION, RECEIVER, 200, sourceChainId, sourceBlock, nonce, "");
        assertEq(
            uint256(bridge.receivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Success),
            "message should be successful"
        );

        vm.expectRevert(bytes4(keccak256("MessageReceivedOutOfOrder()")));
        bridge.receiveMessage{value: 200}(DESTINATION, RECEIVER, 200, sourceChainId, sourceBlock, nonce, "");
    }

    function test_receiveMessageWithProof_executesTransfer() public {
        vm.deal(address(this), 1 ether);
        uint256 receiverBalanceBefore = RECEIVER.balance;
        _acceptBatchAndExecuteReceiveWithProof();
        uint256 receiverBalanceAfter = RECEIVER.balance;

        assertEq(receiverBalanceAfter - receiverBalanceBefore, 100, "receiver should be paid via proof path");
    }

    function test_receiveMessage_afterDeadline_emitsRollbackBehavior() public {
        vm.deal(address(this), 1 ether);
        uint256 nonce = bridge.receivedNonce();
        uint256 sourceChainId = block.chainid + 1;
        uint256 sourceBlock = 10;

        oracle.updateL1BlockNumber(1000);

        // Use a contract receiver to ensure its handler is never called when deadline has passed.
        NoopReceiver receiver = new NoopReceiver();
        uint256 receiverBalanceBefore = address(receiver).balance;
        bytes memory payload = abi.encodeWithSignature("handle()");
        bridge.receiveMessage{value: 200}(DESTINATION, address(receiver), 200, sourceChainId, sourceBlock, nonce, payload);
        uint256 receiverBalanceAfter = address(receiver).balance;

        assertEq(receiverBalanceAfter - receiverBalanceBefore, 0, "message must not execute after deadline");

        bytes32 messageHash =
            _bridgeMessageHash(DESTINATION, address(receiver), 200, sourceChainId, sourceBlock, nonce, payload);
        assertEq(
            uint256(bridge.receivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.None),
            "deadline path keeps status unchanged"
        );
    }

    function test_receiveFailedMessage_replaysFailedCall() public {
        // Arrange: send a message to a receiver that always reverts so status becomes Failed.
        RevertingReceiver receiver = new RevertingReceiver();
        uint256 nonce = bridge.receivedNonce();
        uint256 sourceChainId = block.chainid + 1;
        uint256 sourceBlock = 1;
        bytes memory payload = abi.encodeWithSignature("fail()");

        bytes32 messageHash =
            _bridgeMessageHash(OTHER_BRIDGE, address(receiver), 0, sourceChainId, sourceBlock, nonce, payload);

        bridge.receiveMessage(OTHER_BRIDGE, address(receiver), 0, sourceChainId, sourceBlock, nonce, payload);
        assertEq(
            uint256(bridge.receivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "initial receive should mark message as failed"
        );

        // Act: call receiveFailedMessage with the same parameters.
        vm.recordLogs();
        bridge.receiveFailedMessage(OTHER_BRIDGE, address(receiver), 0, sourceChainId, sourceBlock, nonce, payload);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool replayed;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(bridge) && logs[i].topics.length == 1) {
                // ReceivedMessage(bytes32,bool,bytes)
                (bytes32 loggedHash,,) = abi.decode(logs[i].data, (bytes32, bool, bytes));
                if (loggedHash == messageHash) {
                    replayed = true;
                    break;
                }
            }
        }
        assertTrue(replayed, "failed replay path must emit ReceivedMessage for the same hash");

        // Assert: status remains Failed but the failed-path entrypoint is exercised.
        assertEq(
            uint256(bridge.receivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "status should remain failed after failed replay"
        );
    }

    function test_rollbackMessageWithProof_refundsOriginalSender() public {
        vm.deal(USER, 1 ether);
        vm.deal(address(bridge), MSG_VALUE);

        uint256 sourceChainId = block.chainid + 1;
        uint256 msgNonce = 7;
        uint256 sourceBlock = 77;

        bytes32 blockHash1 = keccak256("rollback-block-1");
        bytes32 blockHash2 = keccak256("rollback-block-2");

        RollupStorageLayout.BlockCommitment[] memory batch = new RollupStorageLayout.BlockCommitment[](2);
        batch[0] = _buildCommitment(
            MOCK_GENESIS_HASH,
            blockHash1,
            _bridgeMessageHash(USER, DESTINATION, MSG_VALUE, sourceChainId, sourceBlock, msgNonce, PAYLOAD),
            ZERO_HASH
        );
        batch[1] = _buildCommitment(blockHash1, blockHash2, ZERO_HASH, ZERO_HASH);

        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(batch, new RollupStorageLayout.DepositsInBlock[](0), 0);
        vm.roll(block.number + 2);

        uint256 userBalanceBefore = USER.balance;
        _executeRollback(batch[0], sourceBlock, msgNonce, _commitmentHash(batch[1]));

        assertEq(USER.balance, userBalanceBefore + MSG_VALUE, "rollback should refund sender");
    }

    function test_sendMessage_revertsForBridgeDestinations() public {
        vm.deal(USER, 1 ether);

        vm.prank(USER);
        vm.expectRevert(bytes4(keccak256("InvalidDestinationAddress()")));
        bridge.sendMessage{value: MSG_VALUE}(address(bridge), PAYLOAD);

        vm.prank(USER);
        vm.expectRevert(bytes4(keccak256("InvalidDestinationAddress()")));
        bridge.sendMessage{value: MSG_VALUE}(OTHER_BRIDGE, PAYLOAD);
    }

    function test_pauseBlocksSendAndReceive_untilUnpaused() public {
        bridge.pause();
        assertEq(bridge.paused(), true, "bridge should be paused");

        vm.deal(USER, 1 ether);
        vm.prank(USER);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        bridge.sendMessage{value: MSG_VALUE}(DESTINATION, PAYLOAD);

        bridge.unpause();
        assertEq(bridge.paused(), false, "bridge should be unpaused");

        vm.prank(USER);
        bridge.sendMessage{value: MSG_VALUE}(DESTINATION, PAYLOAD);
        assertEq(bridge.sentMessageQueueSize(), 1, "send should work after unpause");
    }

    function _executeRollback(
        RollupStorageLayout.BlockCommitment memory commitment,
        uint256 sourceBlock,
        uint256 msgNonce,
        bytes32 blockSibling
    ) internal {
        bridge.rollbackMessageWithProof(
            1,
            commitment,
            USER,
            DESTINATION,
            MSG_VALUE,
            block.chainid + 1,
            sourceBlock,
            msgNonce,
            PAYLOAD,
            _proofForSingleLeaf(),
            _proofForTwoLeaves(0, blockSibling)
        );
    }

    function _executeReceiveWithProof(
        RollupStorageLayout.BlockCommitment memory commitment,
        uint256 sourceChainId,
        uint256 sourceBlock,
        uint256 nonce,
        bytes32 withdrawalSibling,
        bytes32 blockSibling
    ) internal {
        bridge.receiveMessageWithProof{value: 100}(
            1,
            commitment,
            DESTINATION,
            payable(RECEIVER),
            100,
            sourceChainId,
            sourceBlock,
            nonce,
            "",
            _proofForTwoLeaves(0, withdrawalSibling),
            _proofForTwoLeaves(0, blockSibling)
        );
    }

    function _acceptBatchAndExecuteReceiveWithProof() internal {
        uint256 nonce = bridge.receivedNonce();
        uint256 sourceChainId = block.chainid + 1;
        uint256 sourceBlock = 11;
        bytes32 messageHash1 = _bridgeMessageHash(DESTINATION, RECEIVER, 100, sourceChainId, sourceBlock, nonce, "");
        bytes32 messageHash2 = _bridgeMessageHash(DESTINATION, RECEIVER, 200, sourceChainId, 0, nonce + 1, "");
        bytes32 withdrawalRoot = _hashPair(messageHash1, messageHash2);

        bytes32 blockHash1 = keccak256("withdrawal-proof-block-1");
        bytes32 blockHash2 = keccak256("withdrawal-proof-block-2");

        RollupStorageLayout.BlockCommitment[] memory batch = new RollupStorageLayout.BlockCommitment[](2);
        batch[0] = _buildCommitment(MOCK_GENESIS_HASH, blockHash1, withdrawalRoot, ZERO_HASH);
        batch[1] = _buildCommitment(blockHash1, blockHash2, ZERO_HASH, ZERO_HASH);

        bytes32 blockSibling = _commitmentHash(batch[1]);

        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(batch, new RollupStorageLayout.DepositsInBlock[](0), 0);

        vm.roll(block.number + 2);
        _executeReceiveWithProof(batch[0], sourceChainId, sourceBlock, nonce, messageHash2, blockSibling);
    }
}
