// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IFluentBridge, IFluentBridgeErrors, IFluentBridgeEvents} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {L1BlockOracle} from "../../contracts/oracles/L1BlockOracle.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {L2BlockHeader} from "../../contracts/interfaces/rollup/IRollupTypes.sol";
import {MockRollup} from "../mocks/MockRollup.sol";
import {BridgeBase, RevertingReceiver, NoopReceiver} from "./Base.t.sol";

/**
 * @notice In-process L1↔L2 harness — both bridges in one test, no forks.
 * @dev Exercises the full rollback lifecycle for the two non-trivial paths of the split
 *      `receiveMessage` / `receiveFailedMessage` design:
 *        - Case B2: target revert on first delivery → retry after expiry emits RollbackMessage
 *                   (first and only emission) → L1 proof-based refund.
 *        - Case A double-emit: first delivery already expired → RollbackMessage in block N,
 *                   retry in block M re-emits it. L1 `_rollbackMessages` dedup blocks the
 *                   second claim.
 */
contract BridgeCrossChainRollbackTest is BridgeBase {
    MockRollup internal rollup;
    L1BlockOracle internal l2OracleOfL1Block;

    function setUp() public override {
        super.setUp();

        // Attach a real MockRollup to L1 bridge so `rollbackMessageWithProof` can verify proofs.
        rollup = new MockRollup();
        vm.prank(admin);
        l1Bridge.setRollup(address(rollup));

        // L2 bridge reads the L1 block number from this oracle; tests advance it to cross the deadline.
        l2OracleOfL1Block = L1BlockOracle(l2Bridge.getL1BlockOracle());
    }

    /// @dev Builds a singleton-leaf L2 block header where `withdrawalRoot == messageHash` and registers
    ///      it as a finalized batch in the mock rollup. After this, `rollbackMessageWithProof` can be
    ///      called with empty Merkle proofs for the single leaf.
    function _finalizeSingleRollbackLeaf(uint256 batchIndex, bytes32 messageHash) internal returns (L2BlockHeader memory header) {
        header = L2BlockHeader({
            previousBlockHash: bytes32(uint256(1)),
            blockHash: bytes32(uint256(2)),
            withdrawalRoot: messageHash,
            depositRoot: bytes32(0),
            depositCount: 0
        });
        bytes32 commitment = keccak256(
            abi.encodePacked(header.previousBlockHash, header.blockHash, header.withdrawalRoot, header.depositRoot)
        );
        rollup.setBatchRoot(batchIndex, commitment);
        rollup.setFinalized(true);
    }

    /// @notice Case B2 end-to-end: L1 `sendMessage` → L2 first delivery reverts (status=Failed, no
    ///         rollback emitted) → L1 oracle advances past the committed deadline → retry on L2 emits
    ///         `RollbackMessage` → L1 `rollbackMessageWithProof` refunds the sender.
    function test_receiveFailedMessage_expiredRetryRefundsOnL1() public {
        address sender = makeAddr("sender");

        // 1. L1 side: fund sender, call sendMessage to a reverting L2 target.
        RevertingReceiver receiver = new RevertingReceiver();
        bytes memory payload = abi.encodeCall(RevertingReceiver.fail, ());
        uint256 value = 1 ether;

        vm.deal(sender, value);
        uint256 nonceAtSend = l1Bridge.getNonce();
        uint256 blockAtSend = block.number;

        vm.prank(sender);
        l1Bridge.sendMessage{value: value}(address(receiver), payload);

        // Deadline is the L1 init param: 100 blocks from sendMessage (see BridgeBase.setUp).
        uint256 validUntilBlockNumber = blockAtSend + 100;
        bytes32 messageHash = keccak256(
            abi.encode(sender, address(receiver), value, block.chainid, validUntilBlockNumber, nonceAtSend, payload)
        );
        assertEq(address(l1Bridge).balance, value, "L1 bridge should hold locked value");

        // 2. L2 first delivery: not yet expired → target is called and reverts → Failed.
        //    No RollbackMessage at this stage.
        vm.prank(relayer);
        vm.deal(address(l2Bridge), value);
        l2Bridge.receiveMessage(sender, address(receiver), value, block.chainid, validUntilBlockNumber, nonceAtSend, payload);
        assertEq(
            uint256(l2Bridge.getReceivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "status after first delivery should be Failed"
        );

        // 3. Advance L2's view of the L1 block number past the committed deadline.
        vm.prank(relayer);
        l2OracleOfL1Block.updateL1BlockNumber(validUntilBlockNumber + 1);

        // 4. Retry on L2: expiry hits the retry hook → emits RollbackMessage (first emission) and
        //    RetriedFailedMessage(false, ""). Status stays Failed.
        vm.expectEmit(true, true, true, true, address(l2Bridge));
        emit IFluentBridgeEvents.RollbackMessage(messageHash, block.number);
        vm.expectEmit(true, true, true, true, address(l2Bridge));
        emit IFluentBridgeEvents.RetriedFailedMessage(messageHash, false, "");

        vm.deal(address(l2Bridge), value);
        l2Bridge.receiveFailedMessage(sender, address(receiver), value, block.chainid, validUntilBlockNumber, nonceAtSend, payload);
        assertEq(
            uint256(l2Bridge.getReceivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "status after expired retry should stay Failed"
        );

        // 5. L1 side: fabricate a finalized batch whose withdrawalRoot is exactly this messageHash,
        //    then claim rollback. L1 bridge refunds from the locked balance.
        L2BlockHeader memory header = _finalizeSingleRollbackLeaf(1, messageHash);
        MerkleTree.MerkleProof memory emptyProof = MerkleTree.MerkleProof({nonce: 0, proof: ""});

        uint256 senderBalBefore = sender.balance;
        l1Bridge.rollbackMessageWithProof(
            1,
            header,
            sender,
            address(receiver),
            value,
            block.chainid,
            validUntilBlockNumber,
            nonceAtSend,
            payload,
            emptyProof,
            emptyProof
        );

        assertEq(sender.balance, senderBalBefore + value, "sender should receive the refund");
        assertEq(
            uint8(l1Bridge.getRollbackMessage(messageHash)),
            uint8(IFluentBridge.MessageStatus.Success),
            "rollback claim recorded as Success"
        );
    }

    /// @notice Case A double-emit + L1 dedup: first `receiveMessage` hits expiry immediately →
    ///         RollbackMessage in block N. Retry via `receiveFailedMessage` in block M also sees
    ///         expiry → RollbackMessage in block M. On L1 the first claim against block N succeeds;
    ///         the second claim against block M reverts with `MessageAlreadyReceived` via the
    ///         `_rollbackMessages[hash] != None` dedup.
    function test_rollbackMessageWithProof_rejectsSecondClaimAfterDoubleEmitOnL2() public {
        address sender = makeAddr("sender2");

        NoopReceiver receiver = new NoopReceiver();
        bytes memory payload = abi.encodeCall(NoopReceiver.handle, ());
        // Value = 0 so the second claim is not short-circuited by `InsufficientBridgeBalance`
        // (balance check runs before the dedup). We are exercising the dedup, not the balance path.
        uint256 value = 0;

        uint256 nonceAtSend = l1Bridge.getNonce();
        uint256 blockAtSend = block.number;

        vm.prank(sender);
        l1Bridge.sendMessage(address(receiver), payload);

        uint256 validUntilBlockNumber = blockAtSend + 100;
        bytes32 messageHash = keccak256(
            abi.encode(sender, address(receiver), value, block.chainid, validUntilBlockNumber, nonceAtSend, payload)
        );

        // Oracle already past the committed deadline — first delivery takes the expiry branch.
        vm.prank(relayer);
        l2OracleOfL1Block.updateL1BlockNumber(validUntilBlockNumber + 1);

        uint256 firstEmitBlock = block.number;
        vm.expectEmit(true, true, true, true, address(l2Bridge));
        emit IFluentBridgeEvents.RollbackMessage(messageHash, firstEmitBlock);

        vm.prank(relayer);
        vm.deal(address(l2Bridge), value);
        l2Bridge.receiveMessage(sender, address(receiver), value, block.chainid, validUntilBlockNumber, nonceAtSend, payload);
        assertEq(
            uint256(l2Bridge.getReceivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "status after expired first delivery should be Failed"
        );
        assertEq(receiver.calls(), 0, "target must not be called on expiry path");

        // Advance the EVM block so the retry's RollbackMessage carries a different block.number.
        uint256 secondEmitBlock = firstEmitBlock + 7;
        vm.roll(secondEmitBlock);

        vm.expectEmit(true, true, true, true, address(l2Bridge));
        emit IFluentBridgeEvents.RollbackMessage(messageHash, secondEmitBlock);

        vm.deal(address(l2Bridge), value);
        l2Bridge.receiveFailedMessage(sender, address(receiver), value, block.chainid, validUntilBlockNumber, nonceAtSend, payload);

        // L1 first claim: proof points at the fabricated block N withdrawalRoot — succeeds.
        L2BlockHeader memory header = _finalizeSingleRollbackLeaf(1, messageHash);
        MerkleTree.MerkleProof memory emptyProof = MerkleTree.MerkleProof({nonce: 0, proof: ""});

        l1Bridge.rollbackMessageWithProof(
            1,
            header,
            sender,
            address(receiver),
            value,
            block.chainid,
            validUntilBlockNumber,
            nonceAtSend,
            payload,
            emptyProof,
            emptyProof
        );
        assertEq(
            uint8(l1Bridge.getRollbackMessage(messageHash)),
            uint8(IFluentBridge.MessageStatus.Success),
            "first claim recorded"
        );

        // L1 second claim: new batch carrying the same leaf (mirrors the second emit in block M).
        // Despite a valid proof, the `_rollbackMessages[hash]` dedup must revert.
        L2BlockHeader memory header2 = L2BlockHeader({
            previousBlockHash: bytes32(uint256(42)),
            blockHash: bytes32(uint256(43)),
            withdrawalRoot: messageHash,
            depositRoot: bytes32(0),
            depositCount: 0
        });
        bytes32 commitment2 = keccak256(
            abi.encodePacked(header2.previousBlockHash, header2.blockHash, header2.withdrawalRoot, header2.depositRoot)
        );
        rollup.setBatchRoot(2, commitment2);

        vm.expectRevert(IFluentBridgeErrors.MessageAlreadyReceived.selector);
        l1Bridge.rollbackMessageWithProof(
            2,
            header2,
            sender,
            address(receiver),
            value,
            block.chainid,
            validUntilBlockNumber,
            nonceAtSend,
            payload,
            emptyProof,
            emptyProof
        );
    }
}
