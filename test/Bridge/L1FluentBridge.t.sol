// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(L1FluentBridge.initialize, (abi.encode(cfg), address(rollup))));
        l1Bridge = L1FluentBridge(payable(address(proxy)));
    }

    function test_sendMessage_enqueuesMessage() public {
        l1Bridge.sendMessage(receiver, hex"0102");

        vm.prank(address(rollup));
        (bytes32 msgHash, ) = l1Bridge.popSentMessage();

        assertTrue(msgHash != bytes32(0), "message hash should be queued");
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
        l1Bridge.rollbackMessageWithProof(3, _dummyHeader(), user, receiver, 0, block.chainid + 1, 1, 0, "", _dummyProof(), _dummyProof());
    }

    function test_RevertIf_rollbackMessageWithProof_sourceChainIsLocal() public {
        rollup.setFinalized(true);

        vm.expectRevert(IL1FluentBridge.ForbiddenRollbackReceivedMessage.selector);
        l1Bridge.rollbackMessageWithProof(3, _dummyHeader(), user, receiver, 0, block.chainid, 1, 0, "", _dummyProof(), _dummyProof());
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

        f.messageHash = keccak256(
            abi.encode(f.from, f.to, f.value, f.chainId, f.blockNumber, f.messageNonce, f.message)
        );

        f.header = L2BlockHeader({
            previousBlockHash: bytes32(uint256(1)),
            blockHash: bytes32(uint256(2)),
            withdrawalRoot: f.messageHash,
            depositRoot: bytes32(0),
            depositCount: 0
        });

        bytes32 commitment = keccak256(abi.encodePacked(
            f.header.previousBlockHash,
            f.header.blockHash,
            f.header.withdrawalRoot,
            f.header.depositRoot
        ));
        rollup.setBatchRoot(1, commitment);

        f.emptyProof = MerkleTree.MerkleProof(0, "");
    }

    function _executeReceiveWithProof(ProofFixture memory f) internal {
        l1Bridge.receiveMessageWithProof(
            1, f.header, f.from, f.to, f.value, f.chainId,
            f.blockNumber, f.messageNonce, f.message,
            f.emptyProof, f.emptyProof
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
        vm.expectRevert(abi.encodeWithSelector(
            IFluentBridgeErrors.ZeroValueNotAllowed.selector, "blockHeader.blockHash"
        ));
        l1Bridge.receiveMessageWithProof(
            1, header, user, payable(receiver), 0,
            block.chainid + 1, 1, 0, "", _dummyProof(), _dummyProof()
        );
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
        vm.expectRevert(abi.encodeWithSelector(
            IFluentBridgeErrors.ZeroValueNotAllowed.selector, "withdrawalRoot"
        ));
        l1Bridge.receiveMessageWithProof(
            1, header, user, payable(receiver), 0,
            block.chainid + 1, 1, 0, "", _dummyProof(), _dummyProof()
        );
    }

    function test_RevertIf_receiveMessageWithProof_invalidBlockProof() public {
        rollup.setFinalized(true);
        rollup.setBatchRoot(1, bytes32(uint256(999)));
        vm.expectRevert(IL1FluentBridge.InvalidBlockProof.selector);
        l1Bridge.receiveMessageWithProof(
            1, _dummyHeader(), user, payable(receiver), 0,
            block.chainid + 1, 1, 0, "", _dummyProof(), _dummyProof()
        );
    }

    function test_RevertIf_receiveMessageWithProof_invalidWithdrawalProof() public {
        rollup.setFinalized(true);
        L2BlockHeader memory header = _dummyHeader();
        bytes32 commitment = keccak256(abi.encodePacked(
            header.previousBlockHash, header.blockHash,
            header.withdrawalRoot, header.depositRoot
        ));
        rollup.setBatchRoot(1, commitment);
        vm.expectRevert(IL1FluentBridge.InvalidWithdrawalProof.selector);
        l1Bridge.receiveMessageWithProof(
            1, header, user, payable(receiver), 0,
            block.chainid + 1, 1, 0, "", _dummyProof(), _dummyProof()
        );
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

        bytes32 messageHash = keccak256(
            abi.encode(from, to, uint256(0), chainId, uint256(1), uint256(0), bytes(""))
        );

        L2BlockHeader memory header = L2BlockHeader({
            previousBlockHash: bytes32(uint256(1)),
            blockHash: bytes32(uint256(2)),
            withdrawalRoot: messageHash,
            depositRoot: bytes32(0),
            depositCount: 0
        });

        bytes32 commitment = keccak256(abi.encodePacked(
            header.previousBlockHash, header.blockHash,
            header.withdrawalRoot, header.depositRoot
        ));
        rollup.setBatchRoot(1, commitment);

        MerkleTree.MerkleProof memory emptyProof = MerkleTree.MerkleProof(0, "");

        vm.expectRevert(IFluentBridgeErrors.ForbiddenSelfCall.selector);
        l1Bridge.receiveMessageWithProof(
            1, header, from, to, 0, chainId, 1, 0, "",
            emptyProof, emptyProof
        );
    }

    // ============ rollbackMessageWithProof ============

    function test_rollbackMessageWithProof_refundsSender() public {
        rollup.setFinalized(true);

        address from = makeAddr("l2sender");
        address to = makeAddr("l2target");
        uint256 value = 1 ether;
        uint256 chainId = block.chainid + 1;

        vm.deal(address(l1Bridge), 10 ether);

        bytes32 messageHash = keccak256(
            abi.encode(from, to, value, chainId, uint256(1), uint256(0), bytes(""))
        );

        L2BlockHeader memory header = L2BlockHeader({
            previousBlockHash: bytes32(uint256(1)),
            blockHash: bytes32(uint256(2)),
            withdrawalRoot: messageHash,
            depositRoot: bytes32(0),
            depositCount: 0
        });

        bytes32 commitment = keccak256(abi.encodePacked(
            header.previousBlockHash, header.blockHash,
            header.withdrawalRoot, header.depositRoot
        ));
        rollup.setBatchRoot(1, commitment);

        MerkleTree.MerkleProof memory emptyProof = MerkleTree.MerkleProof(0, "");

        l1Bridge.rollbackMessageWithProof(
            1, header, from, to, value, chainId, 1, 0, "",
            emptyProof, emptyProof
        );

        assertEq(
            uint8(l1Bridge.getRollbackMessage(messageHash)),
            uint8(IFluentBridge.MessageStatus.Success),
            "rollback should succeed"
        );
    }

    function test_RevertIf_rollbackMessageWithProof_insufficientBalance() public {
        rollup.setFinalized(true);
        vm.expectRevert(abi.encodeWithSelector(
            IL1FluentBridge.InsufficientBridgeBalance.selector, 1 ether
        ));
        l1Bridge.rollbackMessageWithProof(
            1, _dummyHeader(), user, receiver, 1 ether,
            block.chainid + 1, 1, 0, "", _dummyProof(), _dummyProof()
        );
    }

    function test_RevertIf_rollbackMessageWithProof_rollbackAlreadyDone() public {
        rollup.setFinalized(true);

        address from = makeAddr("l2sender");
        address to = makeAddr("l2target");
        uint256 chainId = block.chainid + 1;

        bytes32 messageHash = keccak256(
            abi.encode(from, to, uint256(0), chainId, uint256(1), uint256(0), bytes(""))
        );

        L2BlockHeader memory header = L2BlockHeader({
            previousBlockHash: bytes32(uint256(1)),
            blockHash: bytes32(uint256(2)),
            withdrawalRoot: messageHash,
            depositRoot: bytes32(0),
            depositCount: 0
        });

        bytes32 commitment = keccak256(abi.encodePacked(
            header.previousBlockHash, header.blockHash,
            header.withdrawalRoot, header.depositRoot
        ));
        rollup.setBatchRoot(1, commitment);

        MerkleTree.MerkleProof memory emptyProof = MerkleTree.MerkleProof(0, "");

        l1Bridge.rollbackMessageWithProof(
            1, header, from, to, 0, chainId, 1, 0, "",
            emptyProof, emptyProof
        );

        vm.expectRevert(IFluentBridgeErrors.MessageAlreadyReceived.selector);
        l1Bridge.rollbackMessageWithProof(
            1, header, from, to, 0, chainId, 1, 0, "",
            emptyProof, emptyProof
        );
    }

    // ============ getRollbackMessage ============

    function test_getRollbackMessage_returnsStoredStatus() public view {
        assertEq(
            uint8(l1Bridge.getRollbackMessage(bytes32(uint256(42)))),
            uint8(IFluentBridge.MessageStatus.None),
            "default rollback status should be None"
        );
    }
}
