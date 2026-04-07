// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vm} from "forge-std/Vm.sol";

import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {FluentBridgeStorageLayout} from "../../contracts/bridge/FluentBridgeStorageLayout.sol";
import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {IL1FluentBridge} from "../../contracts/interfaces/bridge/IL1FluentBridge.sol";
import {IFluentBridgeErrors} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {L2BlockHeader} from "../../contracts/interfaces/IRollupTypes.sol";
import {Queue} from "../../contracts/libraries/Queue.sol";
import {MockRollup} from "../mocks/MockRollup.sol";
import {BridgeBase, NoopReceiver} from "./Base.t.sol";

contract L1FluentBridgeTest is BridgeBase {
    bytes32 internal constant SENT_MESSAGE_SIG = keccak256("SentMessage(address,address,uint256,uint256,uint256,uint256,bytes32,bytes)");

    address internal otherBridge = makeAddr("otherBridge");
    address internal user = makeAddr("user");
    address internal receiver = makeAddr("receiver");
    address internal nonRollup = makeAddr("nonRollup");

    MockRollup internal rollup;

    function setUp() public override {
        rollup = new MockRollup();

        FluentBridgeStorageLayout.InitConfiguration memory cfg = FluentBridgeStorageLayout.InitConfiguration({
            adminRole: admin,
            pauserRole: pauser,
            relayerRole: relayer,
            otherBridge: otherBridge
        });

        L1FluentBridge impl = new L1FluentBridge();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                L1FluentBridge.initialize,
                (abi.encode(cfg), address(rollup), RECEIVE_MESSAGE_DEADLINE, ACCEPT_DEPOSIT_DEADLINE)
            )
        );
        l1Bridge = L1FluentBridge(payable(address(proxy)));
    }

    function test_sendMessage_enqueuesMessage() public {
        l1Bridge.sendMessage(receiver, hex"0102");

        vm.prank(address(rollup));
        (bytes32 msgHash, ) = l1Bridge.popSentMessage();

        assertTrue(msgHash != bytes32(0), "message hash should be queued");
    }

    function test_sendMessage_commitsConfiguredValidUntilBlockNumber() public {
        vm.recordLogs();
        l1Bridge.sendMessage(receiver, hex"0102");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != SENT_MESSAGE_SIG) continue;

            (, , uint256 validUntilBlockNumber, , , ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, bytes32, bytes));
            assertEq(validUntilBlockNumber, block.number + RECEIVE_MESSAGE_DEADLINE, "unexpected validUntilBlockNumber");
            return;
        }

        fail("SentMessage log not found");
    }

    function test_sendMessage_snapshotsCurrentAcceptDepositDeadlineInQueue() public {
        uint256 queuedAtBlock = block.number;
        l1Bridge.sendMessage(receiver, hex"0102");

        (, uint256 acceptByBlockNumber) = l1Bridge.peekSentMessage(0);
        assertEq(
            acceptByBlockNumber,
            queuedAtBlock + l1Bridge.getAcceptDepositDeadline(),
            "queue should snapshot the current bridge deposit deadline"
        );
    }

    function test_sendMessage_afterAcceptDepositDeadlineUpdate_usesNewQueueDeadline() public {
        vm.prank(admin);
        l1Bridge.setAcceptDepositDeadline(25);

        uint256 queuedAtBlock = block.number;
        l1Bridge.sendMessage(receiver, hex"0102");

        (, uint256 acceptByBlockNumber) = l1Bridge.peekSentMessage(0);
        assertEq(acceptByBlockNumber, queuedAtBlock + 25, "newly queued deposits should use the updated deadline");
    }

    function test_pushSentMessage_restoresWithFreshAcceptByBlockNumber() public {
        l1Bridge.sendMessage(receiver, hex"0102");

        vm.prank(address(rollup));
        (bytes32 messageHash, ) = l1Bridge.popSentMessage();

        vm.prank(admin);
        l1Bridge.setAcceptDepositDeadline(25);
        vm.roll(block.number + 7);
        uint256 restoredAtBlock = block.number;

        vm.prank(address(rollup));
        l1Bridge.pushSentMessage(messageHash);

        (, uint256 acceptByBlockNumber) = l1Bridge.peekSentMessage(0);
        assertEq(acceptByBlockNumber, restoredAtBlock + 25, "restored deposits should get a fresh deadline snapshot");
    }

    function test_RevertIf_popSentMessage_queueEmpty() public {
        vm.prank(address(rollup));
        vm.expectRevert(Queue.QueueEmpty.selector);
        l1Bridge.popSentMessage();
    }

    function test_RevertIf_popSentMessage_callerNotRollup() public {
        vm.prank(nonRollup);
        vm.expectRevert(IL1FluentBridge.OnlyRollup.selector);
        l1Bridge.popSentMessage();
    }

    function test_RevertIf_setRollup_queueNotEmpty() public {
        l1Bridge.sendMessage(receiver, hex"deadbeef");

        vm.prank(admin);
        vm.expectRevert(IL1FluentBridge.QueueNotEmpty.selector);
        l1Bridge.setRollup(makeAddr("nextRollup"));
    }

    function test_RevertIf_receiveMessageWithProof_batchNotFinalized() public {
        rollup.setFinalized(false);

        vm.expectRevert(IL1FluentBridge.InvalidBlockProof.selector);
        l1Bridge.receiveMessageWithProof(
            7,
            _dummyHeader(),
            user,
            payable(receiver),
            0,
            block.chainid + 1,
            1,
            0,
            "",
            _dummyProof(),
            _dummyProof()
        );
    }

    function test_RevertIf_receiveMessageWithProof_sourceChainIsLocal() public {
        rollup.setFinalized(true);

        vm.expectRevert(IL1FluentBridge.ForbiddenReceiveRollbackMessage.selector);
        l1Bridge.receiveMessageWithProof(1, _dummyHeader(), user, payable(receiver), 0, block.chainid, 1, 0, "", _dummyProof(), _dummyProof());
    }

    function test_RevertIf_rollbackMessageWithProof_batchNotFinalized() public {
        rollup.setFinalized(false);

        vm.expectRevert(IL1FluentBridge.InvalidBlockProof.selector);
        l1Bridge.rollbackMessageWithProof(3, _dummyHeader(), user, receiver, 0, block.chainid, 1, 0, "", _dummyProof(), _dummyProof());
    }

    function test_RevertIf_rollbackMessageWithProof_sourceChainIsForeign() public {
        rollup.setFinalized(true);

        vm.expectRevert(IL1FluentBridge.ForbiddenRollbackReceivedMessage.selector);
        l1Bridge.rollbackMessageWithProof(3, _dummyHeader(), user, receiver, 0, block.chainid + 1, 1, 0, "", _dummyProof(), _dummyProof());
    }

    // ============ Proof path helpers ============

    struct ProofFixture {
        address from;
        address payable to;
        uint256 value;
        uint256 chainId;
        uint256 blockNumber;
        uint256 messageNonce;
        bytes message;
        bytes32 messageHash;
        L2BlockHeader header;
        MerkleTree.MerkleProof emptyProof;
    }

    function _validProofFixture() internal returns (ProofFixture memory f) {
        rollup.setFinalized(true);

        f.from = makeAddr("l2sender");
        f.to = payable(address(new NoopReceiver()));
        f.value = 0;
        f.chainId = block.chainid + 1;
        f.blockNumber = 1;
        f.messageNonce = 0;
        f.message = abi.encodeCall(NoopReceiver.handle, ());

        f.messageHash = keccak256(abi.encode(f.from, f.to, f.value, f.chainId, f.blockNumber, f.messageNonce, f.message));

        f.header = L2BlockHeader({
            previousBlockHash: bytes32(uint256(1)),
            blockHash: bytes32(uint256(2)),
            withdrawalRoot: f.messageHash,
            depositRoot: bytes32(0),
            depositCount: 0
        });

        bytes32 commitment = keccak256(
            abi.encodePacked(f.header.previousBlockHash, f.header.blockHash, f.header.withdrawalRoot, f.header.depositRoot)
        );
        rollup.setBatchRoot(1, commitment);

        f.emptyProof = MerkleTree.MerkleProof(0, "");
    }

    function _executeReceiveWithProof(ProofFixture memory f) internal {
        l1Bridge.receiveMessageWithProof(
            1,
            f.header,
            f.from,
            f.to,
            f.value,
            f.chainId,
            f.blockNumber,
            f.messageNonce,
            f.message,
            f.emptyProof,
            f.emptyProof
        );
    }

    // ============ receiveMessageWithProof happy path ============

    function test_receiveMessageWithProof_executesMessageOnValidProof() public {
        ProofFixture memory f = _validProofFixture();
        _executeReceiveWithProof(f);

        assertEq(
            uint8(l1Bridge.getReceivedMessage(f.messageHash)),
            uint8(IFluentBridge.MessageStatus.Success),
            "message should be marked as received"
        );
    }

    // ============ receiveMessageWithProof revert paths ============

    function test_RevertIf_receiveMessageWithProof_zeroBlockHash() public {
        rollup.setFinalized(true);
        L2BlockHeader memory header = L2BlockHeader({
            previousBlockHash: bytes32(uint256(1)),
            blockHash: bytes32(0),
            withdrawalRoot: bytes32(uint256(3)),
            depositRoot: bytes32(0),
            depositCount: 0
        });
        vm.expectRevert(abi.encodeWithSelector(IFluentBridgeErrors.ZeroValueNotAllowed.selector, "blockHeader.blockHash"));
        l1Bridge.receiveMessageWithProof(1, header, user, payable(receiver), 0, block.chainid + 1, 1, 0, "", _dummyProof(), _dummyProof());
    }

    function test_RevertIf_receiveMessageWithProof_zeroWithdrawalRoot() public {
        rollup.setFinalized(true);
        L2BlockHeader memory header = L2BlockHeader({
            previousBlockHash: bytes32(uint256(1)),
            blockHash: bytes32(uint256(2)),
            withdrawalRoot: bytes32(0),
            depositRoot: bytes32(0),
            depositCount: 0
        });
        vm.expectRevert(abi.encodeWithSelector(IFluentBridgeErrors.ZeroValueNotAllowed.selector, "withdrawalRoot"));
        l1Bridge.receiveMessageWithProof(1, header, user, payable(receiver), 0, block.chainid + 1, 1, 0, "", _dummyProof(), _dummyProof());
    }

    function test_RevertIf_receiveMessageWithProof_invalidBlockProof() public {
        rollup.setFinalized(true);
        rollup.setBatchRoot(1, bytes32(uint256(999)));
        vm.expectRevert(IL1FluentBridge.InvalidBlockProof.selector);
        l1Bridge.receiveMessageWithProof(
            1,
            _dummyHeader(),
            user,
            payable(receiver),
            0,
            block.chainid + 1,
            1,
            0,
            "",
            _dummyProof(),
            _dummyProof()
        );
    }

    function test_RevertIf_receiveMessageWithProof_invalidWithdrawalProof() public {
        rollup.setFinalized(true);
        L2BlockHeader memory header = _dummyHeader();
        bytes32 commitment = keccak256(abi.encodePacked(header.previousBlockHash, header.blockHash, header.withdrawalRoot, header.depositRoot));
        rollup.setBatchRoot(1, commitment);
        vm.expectRevert(IL1FluentBridge.InvalidWithdrawalProof.selector);
        l1Bridge.receiveMessageWithProof(1, header, user, payable(receiver), 0, block.chainid + 1, 1, 0, "", _dummyProof(), _dummyProof());
    }

    function test_RevertIf_receiveMessageWithProof_messageAlreadyReceived() public {
        ProofFixture memory f = _validProofFixture();
        _executeReceiveWithProof(f);

        vm.expectRevert(IFluentBridgeErrors.MessageAlreadyReceived.selector);
        _executeReceiveWithProof(f);
    }

    function test_RevertIf_receiveMessageWithProof_selfCall() public {
        rollup.setFinalized(true);

        address from = makeAddr("l2sender");
        address payable to = payable(address(l1Bridge));
        uint256 chainId = block.chainid + 1;

        bytes32 messageHash = keccak256(abi.encode(from, to, uint256(0), chainId, uint256(1), uint256(0), bytes("")));

        L2BlockHeader memory header = L2BlockHeader({
            previousBlockHash: bytes32(uint256(1)),
            blockHash: bytes32(uint256(2)),
            withdrawalRoot: messageHash,
            depositRoot: bytes32(0),
            depositCount: 0
        });

        bytes32 commitment = keccak256(abi.encodePacked(header.previousBlockHash, header.blockHash, header.withdrawalRoot, header.depositRoot));
        rollup.setBatchRoot(1, commitment);

        MerkleTree.MerkleProof memory emptyProof = MerkleTree.MerkleProof(0, "");

        vm.expectRevert(IFluentBridgeErrors.ForbiddenSelfCall.selector);
        l1Bridge.receiveMessageWithProof(1, header, from, to, 0, chainId, 1, 0, "", emptyProof, emptyProof);
    }

    // ============ rollbackMessageWithProof ============

    function test_rollbackMessageWithProof_refundsSender() public {
        rollup.setFinalized(true);

        address from = makeAddr("l1sender");
        address to = makeAddr("l2target");
        uint256 value = 1 ether;
        uint256 chainId = block.chainid;

        vm.deal(address(l1Bridge), 10 ether);

        bytes32 messageHash = keccak256(abi.encode(from, to, value, chainId, uint256(1), uint256(0), bytes("")));

        L2BlockHeader memory header = L2BlockHeader({
            previousBlockHash: bytes32(uint256(1)),
            blockHash: bytes32(uint256(2)),
            withdrawalRoot: messageHash,
            depositRoot: bytes32(0),
            depositCount: 0
        });

        bytes32 commitment = keccak256(abi.encodePacked(header.previousBlockHash, header.blockHash, header.withdrawalRoot, header.depositRoot));
        rollup.setBatchRoot(1, commitment);

        MerkleTree.MerkleProof memory emptyProof = MerkleTree.MerkleProof(0, "");

        l1Bridge.rollbackMessageWithProof(1, header, from, to, value, chainId, 1, 0, "", emptyProof, emptyProof);

        assertEq(uint8(l1Bridge.getRollbackMessage(messageHash)), uint8(IFluentBridge.MessageStatus.Success), "rollback should succeed");
    }

    function test_RevertIf_rollbackMessageWithProof_insufficientBalance() public {
        rollup.setFinalized(true);
        vm.expectRevert(abi.encodeWithSelector(IFluentBridgeErrors.InsufficientBridgeBalance.selector, 1 ether));
        l1Bridge.rollbackMessageWithProof(1, _dummyHeader(), user, receiver, 1 ether, block.chainid, 1, 0, "", _dummyProof(), _dummyProof());
    }

    function test_RevertIf_rollbackMessageWithProof_rollbackAlreadyDone() public {
        rollup.setFinalized(true);

        address from = makeAddr("l1sender");
        address to = makeAddr("l2target");
        uint256 chainId = block.chainid;

        bytes32 messageHash = keccak256(abi.encode(from, to, uint256(0), chainId, uint256(1), uint256(0), bytes("")));

        L2BlockHeader memory header = L2BlockHeader({
            previousBlockHash: bytes32(uint256(1)),
            blockHash: bytes32(uint256(2)),
            withdrawalRoot: messageHash,
            depositRoot: bytes32(0),
            depositCount: 0
        });

        bytes32 commitment = keccak256(abi.encodePacked(header.previousBlockHash, header.blockHash, header.withdrawalRoot, header.depositRoot));
        rollup.setBatchRoot(1, commitment);

        MerkleTree.MerkleProof memory emptyProof = MerkleTree.MerkleProof(0, "");

        l1Bridge.rollbackMessageWithProof(1, header, from, to, 0, chainId, 1, 0, "", emptyProof, emptyProof);

        vm.expectRevert(IFluentBridgeErrors.MessageAlreadyReceived.selector);
        l1Bridge.rollbackMessageWithProof(1, header, from, to, 0, chainId, 1, 0, "", emptyProof, emptyProof);
    }

    // ============ peekSentMessage ============

    function test_peekSentMessage_returnsCorrectEntry() public {
        l1Bridge.sendMessage(receiver, hex"01");
        l1Bridge.sendMessage(receiver, hex"02");

        (bytes32 hash0,) = l1Bridge.peekSentMessage(0);
        (bytes32 hash1,) = l1Bridge.peekSentMessage(1);

        assertTrue(hash0 != bytes32(0), "first message hash should be non-zero");
        assertTrue(hash1 != bytes32(0), "second message hash should be non-zero");
        assertTrue(hash0 != hash1, "message hashes should differ");
    }

    function test_RevertIf_peekSentMessage_indexBelowFront() public {
        l1Bridge.sendMessage(receiver, hex"01");

        vm.prank(address(rollup));
        l1Bridge.popSentMessage();

        vm.expectRevert(abi.encodeWithSelector(Queue.QueueOutOfBounds.selector, 0));
        l1Bridge.peekSentMessage(0);
    }

    function test_RevertIf_peekSentMessage_indexAboveBack() public {
        l1Bridge.sendMessage(receiver, hex"01");

        vm.expectRevert(abi.encodeWithSelector(Queue.QueueOutOfBounds.selector, 1));
        l1Bridge.peekSentMessage(1);
    }

    // ============ sentMessageQueueFront / sentMessageQueueBack ============

    function test_sentMessageQueueFront_returnsCurrentFront() public {
        assertEq(l1Bridge.sentMessageQueueFront(), 0, "initial front should be 0");

        l1Bridge.sendMessage(receiver, hex"01");

        vm.prank(address(rollup));
        l1Bridge.popSentMessage();

        assertEq(l1Bridge.sentMessageQueueFront(), 1, "front should advance after pop");
    }

    function test_sentMessageQueueBack_returnsCurrentBack() public {
        assertEq(l1Bridge.sentMessageQueueBack(), 0, "initial back should be 0");

        l1Bridge.sendMessage(receiver, hex"01");
        assertEq(l1Bridge.sentMessageQueueBack(), 1, "back should advance after enqueue");

        l1Bridge.sendMessage(receiver, hex"02");
        assertEq(l1Bridge.sentMessageQueueBack(), 2, "back should advance after second enqueue");
    }

    // ============ getRollbackMessage ============

    function test_getRollbackMessage_returnsStoredStatus() public view {
        assertEq(
            uint8(l1Bridge.getRollbackMessage(bytes32(uint256(42)))),
            uint8(IFluentBridge.MessageStatus.None),
            "default rollback status should be None"
        );
    }

    // ============ rollbackMessageWithProof: L1-originated message ============

    /// @dev Verifies that rollbackMessageWithProof accepts messages that originated on
    ///      THIS chain (L1) — the primary rollback use case.
    ///
    ///      Real flow:
    ///        1. User sends 1 ETH from L1→L2 via sendMessage (chainId = block.chainid = L1)
    ///        2. On L2, relayer delivers past deadline → RollbackMessage emitted with ORIGINAL messageHash
    ///        3. Batch finalized on L1
    ///        4. User calls rollbackMessageWithProof on L1 with original params
    ///        5. chainId == block.chainid → passes guard → refund executes
    function test_rollbackMessageWithProof_refundsL1OriginatedDeposit() public {
        rollup.setFinalized(true);

        // When a user calls sendMessage on L1, the message is encoded with
        // chainId = block.chainid (the L1 chain ID where sendMessage is called).
        address depositor = makeAddr("depositor");
        address l2Target = makeAddr("l2Target");
        uint256 depositValue = 1 ether;
        uint256 chainId = block.chainid;

        // Fund the bridge as if the user had called sendMessage{value: 1 ether}
        vm.deal(address(l1Bridge), 10 ether);

        // Reconstruct the same messageHash that would be produced by sendMessage on L1
        // and later included in the L2 block's withdrawalRoot after the rollback on L2
        bytes32 messageHash = keccak256(abi.encode(depositor, l2Target, depositValue, chainId, uint256(1), uint256(0), bytes("")));

        // The L2 sequencer builds a block whose withdrawalRoot contains the rollback messageHash.
        // After batch finalization on L1, this proof becomes verifiable.
        L2BlockHeader memory header = L2BlockHeader({
            previousBlockHash: bytes32(uint256(1)),
            blockHash: bytes32(uint256(2)),
            withdrawalRoot: messageHash,
            depositRoot: bytes32(0),
            depositCount: 0
        });

        bytes32 commitment = keccak256(abi.encodePacked(header.previousBlockHash, header.blockHash, header.withdrawalRoot, header.depositRoot));
        rollup.setBatchRoot(1, commitment);

        MerkleTree.MerkleProof memory emptyProof = MerkleTree.MerkleProof(0, "");

        uint256 depositorBalBefore = depositor.balance;

        l1Bridge.rollbackMessageWithProof(
            1,
            header,
            depositor,
            l2Target,
            depositValue,
            chainId, // == block.chainid — the correct value for an L1-originated message
            1,
            0,
            "",
            emptyProof,
            emptyProof
        );

        assertEq(uint8(l1Bridge.getRollbackMessage(messageHash)), uint8(IFluentBridge.MessageStatus.Success), "rollback should succeed");
        assertEq(depositor.balance, depositorBalBefore + depositValue, "depositor should receive refund");
    }
}
