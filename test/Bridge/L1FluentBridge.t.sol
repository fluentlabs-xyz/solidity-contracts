// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {FluentBridgeStorageLayout} from "../../contracts/bridge/FluentBridgeStorageLayout.sol";
import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {IL1FluentBridge} from "../../contracts/interfaces/bridge/IL1FluentBridge.sol";
import {IFluentBridgeErrors} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {L2BlockHeader} from "../../contracts/interfaces/IRollupTypes.sol";
import {MockRollup} from "../mocks/MockRollup.sol";
import {BridgeBase, NoopReceiver} from "./Base.t.sol";

contract L1FluentBridgeTest is BridgeBase {
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
            abi.encodeCall(L1FluentBridge.initialize, (abi.encode(cfg), address(rollup), 100, 100))
        );
        l1Bridge = L1FluentBridge(payable(address(proxy)));
    }

    function test_sendMessage_enqueuesMessage() public {
        l1Bridge.sendMessage(receiver, hex"0102");

        vm.prank(address(rollup));
        bytes32 msgHash = l1Bridge.consumeNextSentMessage();

        assertTrue(msgHash != bytes32(0), "message hash should be queued");
    }

    function test_RevertIf_consumeNextSentMessage_queueEmpty() public {
        vm.prank(address(rollup));
        vm.expectRevert(IL1FluentBridge.SentMessageQueueEmpty.selector);
        l1Bridge.consumeNextSentMessage();
    }

    function test_RevertIf_consumeNextSentMessage_callerNotRollup() public {
        vm.prank(nonRollup);
        vm.expectRevert(IL1FluentBridge.OnlyRollup.selector);
        l1Bridge.consumeNextSentMessage();
    }

    function test_consumeNextSentMessage_advancesCursor() public {
        l1Bridge.sendMessage(receiver, hex"01");
        l1Bridge.sendMessage(receiver, hex"02");

        assertEq(l1Bridge.getSentMessageCursor(), 0);
        assertEq(l1Bridge.getSentMessageQueueSize(), 2);

        vm.prank(address(rollup));
        l1Bridge.consumeNextSentMessage();
        assertEq(l1Bridge.getSentMessageCursor(), 1);
        assertEq(l1Bridge.getSentMessageQueueSize(), 1);

        vm.prank(address(rollup));
        l1Bridge.consumeNextSentMessage();
        assertEq(l1Bridge.getSentMessageCursor(), 2);
        assertEq(l1Bridge.getSentMessageQueueSize(), 0);
    }

    function test_rewindSentMessageCursor_movesCursorBackward() public {
        l1Bridge.sendMessage(receiver, hex"01");
        l1Bridge.sendMessage(receiver, hex"02");

        vm.prank(address(rollup));
        bytes32 first = l1Bridge.consumeNextSentMessage();
        vm.prank(address(rollup));
        bytes32 second = l1Bridge.consumeNextSentMessage();

        assertEq(l1Bridge.getSentMessageCursor(), 2);

        vm.prank(address(rollup));
        l1Bridge.rewindSentMessageCursor(0);

        assertEq(l1Bridge.getSentMessageCursor(), 0);
        assertEq(l1Bridge.getSentMessageQueueSize(), 2);

        // Re-consume returns the same hashes
        vm.prank(address(rollup));
        assertEq(l1Bridge.consumeNextSentMessage(), first, "re-consumed first");
        vm.prank(address(rollup));
        assertEq(l1Bridge.consumeNextSentMessage(), second, "re-consumed second");
    }

    function test_RevertIf_rewindSentMessageCursor_targetGreaterThanCurrent() public {
        l1Bridge.sendMessage(receiver, hex"01");
        vm.prank(address(rollup));
        l1Bridge.consumeNextSentMessage();
        // currentFront = 1
        vm.prank(address(rollup));
        vm.expectRevert(abi.encodeWithSelector(IL1FluentBridge.InvalidRewindTarget.selector, uint256(2), uint256(1)));
        l1Bridge.rewindSentMessageCursor(2);
    }

    function test_RevertIf_rewindSentMessageCursor_callerNotRollup() public {
        vm.prank(nonRollup);
        vm.expectRevert(IL1FluentBridge.OnlyRollup.selector);
        l1Bridge.rewindSentMessageCursor(0);
    }

    function test_getMessageAt_returnsHashAtIndex() public {
        l1Bridge.sendMessage(receiver, hex"01");
        l1Bridge.sendMessage(receiver, hex"02");

        bytes32 hash0 = l1Bridge.getMessageAt(0);
        bytes32 hash1 = l1Bridge.getMessageAt(1);

        assertTrue(hash0 != bytes32(0), "index 0 should hold a real hash");
        assertTrue(hash1 != bytes32(0), "index 1 should hold a real hash");
        assertTrue(hash0 != hash1, "two different sends should produce two different hashes");

        // Peek does not advance the cursor — the queue is still full.
        assertEq(l1Bridge.getSentMessageCursor(), 0, "peek must not advance");
        assertEq(l1Bridge.getSentMessageQueueSize(), 2, "peek must not shrink the queue");
    }

    function test_getMessageAt_returnsZeroForOutOfRange() public {
        l1Bridge.sendMessage(receiver, hex"01");

        // By design, getMessageAt has no bounds check — out-of-range indices read from
        // the default value of the underlying mapping and return bytes32(0). Callers are
        // responsible for using getSentMessageCursor/getSentMessageQueueSize to stay in range.
        assertEq(l1Bridge.getMessageAt(1), bytes32(0), "past back returns zero");
        assertEq(l1Bridge.getMessageAt(100), bytes32(0), "far past back returns zero");
    }

    function test_advanceSentMessageCursor_advancesCorrectly() public {
        l1Bridge.sendMessage(receiver, hex"01");
        l1Bridge.sendMessage(receiver, hex"02");
        l1Bridge.sendMessage(receiver, hex"03");

        assertEq(l1Bridge.getSentMessageCursor(), 0);
        assertEq(l1Bridge.getSentMessageQueueSize(), 3);

        vm.prank(address(rollup));
        l1Bridge.advanceSentMessageCursor(2);

        assertEq(l1Bridge.getSentMessageCursor(), 2, "cursor advanced by 2");
        assertEq(l1Bridge.getSentMessageQueueSize(), 1, "one message remains");

        // A second call accumulates.
        vm.prank(address(rollup));
        l1Bridge.advanceSentMessageCursor(1);

        assertEq(l1Bridge.getSentMessageCursor(), 3, "cursor advanced to back");
        assertEq(l1Bridge.getSentMessageQueueSize(), 0, "queue drained");
    }

    function test_advanceSentMessageCursor_batchedConsumeMatchesOneByOne() public {
        // Verify that (peek via getMessageAt) + (bulk advance) is equivalent to
        // N calls to consumeNextSentMessage — same observed hashes, same final cursor.
        l1Bridge.sendMessage(receiver, hex"01");
        l1Bridge.sendMessage(receiver, hex"02");
        l1Bridge.sendMessage(receiver, hex"03");

        uint64 start = l1Bridge.getSentMessageCursor();
        bytes32 peekedA = l1Bridge.getMessageAt(start);
        bytes32 peekedB = l1Bridge.getMessageAt(start + 1);
        bytes32 peekedC = l1Bridge.getMessageAt(start + 2);

        vm.prank(address(rollup));
        l1Bridge.advanceSentMessageCursor(3);

        // Cursor moved to back.
        assertEq(l1Bridge.getSentMessageCursor(), start + 3, "cursor matches bulk advance");

        // The peeked hashes must equal what consumeNextSentMessage would have returned.
        // Rewind and verify by re-consuming one at a time.
        vm.prank(address(rollup));
        l1Bridge.rewindSentMessageCursor(start);

        vm.prank(address(rollup));
        assertEq(l1Bridge.consumeNextSentMessage(), peekedA, "one-by-one A matches peek");
        vm.prank(address(rollup));
        assertEq(l1Bridge.consumeNextSentMessage(), peekedB, "one-by-one B matches peek");
        vm.prank(address(rollup));
        assertEq(l1Bridge.consumeNextSentMessage(), peekedC, "one-by-one C matches peek");
    }

    function test_RevertIf_advanceSentMessageCursor_countExceedsQueueSize() public {
        l1Bridge.sendMessage(receiver, hex"01");
        // queueSize = 1, advance by 2 should revert
        vm.prank(address(rollup));
        vm.expectRevert(abi.encodeWithSelector(IL1FluentBridge.InvalidAdvanceCount.selector, uint256(2), uint256(1)));
        l1Bridge.advanceSentMessageCursor(2);
    }

    function test_RevertIf_advanceSentMessageCursor_callerNotRollup() public {
        l1Bridge.sendMessage(receiver, hex"01");
        vm.prank(nonRollup);
        vm.expectRevert(IL1FluentBridge.OnlyRollup.selector);
        l1Bridge.advanceSentMessageCursor(1);
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
        bytes32 messageHash = keccak256(
            abi.encode(depositor, l2Target, depositValue, chainId, uint256(1), uint256(0), bytes(""))
        );

        // The L2 sequencer builds a block whose withdrawalRoot contains the rollback messageHash.
        // After batch finalization on L1, this proof becomes verifiable.
        L2BlockHeader memory header = L2BlockHeader({
            previousBlockHash: bytes32(uint256(1)),
            blockHash: bytes32(uint256(2)),
            withdrawalRoot: messageHash,
            depositRoot: bytes32(0),
            depositCount: 0
        });

        bytes32 commitment = keccak256(
            abi.encodePacked(header.previousBlockHash, header.blockHash, header.withdrawalRoot, header.depositRoot)
        );
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

        assertEq(
            uint8(l1Bridge.getRollbackMessage(messageHash)),
            uint8(IFluentBridge.MessageStatus.Success),
            "rollback should succeed"
        );
        assertEq(depositor.balance, depositorBalBefore + depositValue, "depositor should receive refund");
    }
}
