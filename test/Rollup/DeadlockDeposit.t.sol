// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RollupAssertions} from "./Base.t.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {L2BlockHeader, BatchStatus, InitConfiguration} from "../../contracts/interfaces/IRollupTypes.sol";
import {MockNitroVerifier} from "../mocks/MockNitroVerifier.sol";
import {MockSp1Verifier} from "../mocks/MockSp1Verifier.sol";
import {MockDepositBridge} from "../mocks/MockDepositBridge.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// ============================================================================
// V-FLNT-VUL-009: Deadlock scenario in rollup due to undeliverable deposits
//
// Audited code (fd208df) had two conflicting deadline mechanisms:
//   1. acceptDepositDeadline (Rollup): reverts acceptNextBatch if deposits sit
//      in the L1 queue past this window — anti-censorship guard.
//   2. receiveMessageDeadline (L2 Bridge): silently skipped expired L1→L2
//      messages without dequeuing from the L1 queue or emitting ReceivedMessage.
//
// A rolled-back deposit stayed at the front of the FIFO queue forever.
// The sequencer could not produce a valid batch referencing it, and eventually
// acceptDepositDeadline fired — permanently halting the rollup.
//
// Fix (b47afb7 + subsequent refactoring): L2 bridge now marks expired messages
// as Failed and includes them in the withdrawal root. _checkDeposits validates
// each deposit's blockNumber against acceptDepositDeadline at pop time, and
// rolled-back deposits are consumable by the sequencer.
// ============================================================================

contract DeadlockDepositTest is RollupAssertions {
    uint256 internal constant DEPOSIT_DEADLINE = 1000;

    MockDepositBridge internal depositBridge;

    function setUp() public override {
        depositBridge = new MockDepositBridge();
        nitroVerifier = new MockNitroVerifier();
        rollup = _deployRollupWithBridge(address(depositBridge));
    }

    // ============ Test 1: Stale deposit triggers deadline revert ============

    /// @dev Documents the audited deadlock scenario (V-FLNT-VUL-009).
    ///
    /// In the original code a silently rolled-back deposit remained in the L1
    /// queue. Because the queue is FIFO with no skip mechanism, every future
    /// acceptNextBatch call would pop this stale deposit. Eventually
    /// acceptDepositDeadline fired and the rollup halted permanently.
    ///
    /// In the fixed code this scenario is unreachable: L2 properly handles the
    /// rollback (marks Failed, includes in withdrawal root), so the sequencer
    /// consumes the deposit before the deadline fires. Here we verify that the
    /// per-deposit deadline check _does_ revert when a deposit has aged out —
    /// the safety net still works even though normal operation avoids it.
    function test_RevertIf_acceptNextBatch_staleDepositExceedsDeadline() public {
        uint256 depositBlock = 10;
        bytes32 depositHash = keccak256("stale-deposit");
        depositBridge.enqueue(depositHash, depositBlock);

        // Advance well past the deposit deadline.
        vm.roll(depositBlock + DEPOSIT_DEADLINE + 1);

        // Build a batch that references this deposit in the first block header.
        L2BlockHeader[] memory batch = _makeBatchWithDeposit(GENESIS_HASH, 0, depositHash);

        vm.prank(sequencer);
        vm.expectRevert(
            abi.encodeWithSelector(IRollupErrors.AcceptDepositDeadlineExceeded.selector, depositBlock + DEPOSIT_DEADLINE, block.number)
        );
        rollup.acceptNextBatch(batch, 1);
    }

    // ============ Test 2: Fresh deposit drains queue without deadlock ========

    /// @dev Verifies that a promptly-processed deposit (including one whose L2
    /// execution was a rollback) does NOT block batch acceptance.
    ///
    /// When the L2 bridge properly handles the message (marks as Failed, emits
    /// into withdrawal root), the sequencer produces a valid block header that
    /// references the deposit. _checkDeposits pops it and verifies the
    /// blockNumber is within acceptDepositDeadline — batch succeeds.
    function test_freshDeposit_doesNotBlockBatch() public {
        bytes32 depositHash = keccak256("rollback-deposit");
        depositBridge.enqueue(depositHash, block.number);

        L2BlockHeader[] memory batch = _makeBatchWithDeposit(GENESIS_HASH, 0, depositHash);

        _acceptBatchDirect(batch);

        assertEq(uint8(rollup.getBatch(1).status), uint8(BatchStatus.HeadersSubmitted));
        assertEq(depositBridge.queueSize(), 0, "queue should be drained");
    }

    // ============ Test 3: Censorship protection still works =================

    /// @dev The fix must NOT weaken censorship resistance. If a valid deposit
    /// sits in the queue and the sequencer submits batches without including
    /// it, the deposit eventually ages past acceptDepositDeadline and any
    /// subsequent attempt to pop it reverts — halting the sequencer.
    ///
    /// We must fully finalize batch 1 (which has no deposits) before advancing
    /// past the deposit deadline. Otherwise the rollup enters corrupted state
    /// from submitBlobsWindow expiry on the unfinalised batch, masking the
    /// deposit-specific revert we want to test.
    function test_censorshipProtection_stillBlocks_whenSequencerIgnoresDeposit() public {
        uint256 depositBlock = 100;
        vm.roll(depositBlock);
        bytes32 depositHash = keccak256("censored-deposit");
        depositBridge.enqueue(depositHash, depositBlock);

        // Sequencer submits batch 1 WITHOUT the deposit (no depositRoot set).
        // _checkDeposits is only called for blocks with depositRoot != ZERO_BYTES_HASH.
        L2BlockHeader[] memory batchNoDeposit = _makeBatch(GENESIS_HASH);
        _acceptBatchDirect(batchNoDeposit);

        assertEq(uint8(rollup.getBatch(1).status), uint8(BatchStatus.HeadersSubmitted));
        assertEq(depositBridge.queueSize(), 1, "deposit still in queue");

        // Finalize batch 1 so the rollup stays healthy while time advances.
        _submitBlobsForRollup(rollup, 1);
        _preconfirmBatchForRollup(rollup, 1);
        vm.roll(block.number + FINALIZATION_DELAY + 1);
        rollup.finalizeBatches(1);
        assertTrue(rollup.isBatchFinalized(1));
        assertFalse(rollup.isRollupCorrupted(), "rollup should be healthy");

        // Advance past the deposit deadline.
        vm.roll(depositBlock + DEPOSIT_DEADLINE + 1);

        // The sequencer finally tries to include the expired deposit — it reverts.
        bytes32 lastHash = rollup.lastBlockHashInBatch(1);
        L2BlockHeader[] memory batchWithDeposit = _makeBatchWithDeposit(lastHash, 0, depositHash);

        vm.prank(sequencer);
        vm.expectRevert(
            abi.encodeWithSelector(IRollupErrors.AcceptDepositDeadlineExceeded.selector, depositBlock + DEPOSIT_DEADLINE, block.number)
        );
        rollup.acceptNextBatch(batchWithDeposit, 1);
    }

    // ============ Test 4: Boundary conditions ===============================

    /// @dev At exactly depositBlock + deadline: batch succeeds.
    ///      At depositBlock + deadline + 1: batch reverts.
    function test_depositDeadline_boundaryConditions() public {
        uint256 depositBlock = 50;
        bytes32 depositHash = keccak256("boundary-deposit");
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = depositHash;

        // ── At exact boundary: should succeed ──
        MockDepositBridge bridge1 = new MockDepositBridge();
        bridge1.enqueue(depositHash, depositBlock);
        Rollup rollup1 = _deployRollupWithBridge(address(bridge1));

        L2BlockHeader[] memory batch1 = _makeBatchWithDeposit(GENESIS_HASH, 0, depositHash);

        // block.number <= depositBlock + DEPOSIT_DEADLINE
        vm.roll(depositBlock + DEPOSIT_DEADLINE);
        vm.prank(sequencer);
        rollup1.acceptNextBatch(batch1, 1);

        assertEq(uint8(rollup1.getBatch(1).status), uint8(BatchStatus.HeadersSubmitted), "batch should succeed at exact deadline boundary");

        // ── One block past boundary: should revert ──
        MockDepositBridge bridge2 = new MockDepositBridge();
        bridge2.enqueue(depositHash, depositBlock);
        Rollup rollup2 = _deployRollupWithBridge(address(bridge2));

        L2BlockHeader[] memory batch2 = _makeBatchWithDeposit(GENESIS_HASH, 0, depositHash);

        vm.roll(depositBlock + DEPOSIT_DEADLINE + 1);
        vm.prank(sequencer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRollupErrors.AcceptDepositDeadlineExceeded.selector,
                depositBlock + DEPOSIT_DEADLINE,
                depositBlock + DEPOSIT_DEADLINE + 1
            )
        );
        rollup2.acceptNextBatch(batch2, 1);
    }

    // ============ Internal helpers ==========================================

    function _makeBatchWithDeposit(
        bytes32 parentHash,
        uint256 headerIndex,
        bytes32 depositHash
    ) internal pure returns (L2BlockHeader[] memory batch) {
        batch = _makeBatch(parentHash);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = depositHash;
        batch[headerIndex].depositRoot = keccak256(abi.encodePacked(ids));
        batch[headerIndex].depositCount = 1;
    }

    function _acceptBatchDirect(L2BlockHeader[] memory batch) internal {
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 1);
    }

    function _submitBlobsForRollup(Rollup r, uint256 batchIndex) internal {
        bytes32[] memory h = new bytes32[](1);
        h[0] = keccak256(abi.encode("blob", batchIndex, uint256(0)));
        vm.blobhashes(h);
        vm.prank(sequencer);
        r.submitBlobs(batchIndex, 1);
    }

    function _preconfirmBatchForRollup(Rollup r, uint256 batchIndex) internal {
        vm.prank(preconfirmer);
        r.preconfirmBatch(address(nitroVerifier), batchIndex, DUMMY_SIGNATURE);
    }

    function _deployRollupWithBridge(address bridge) internal returns (Rollup) {
        MockSp1Verifier sp1 = new MockSp1Verifier();
        InitConfiguration memory cfg = InitConfiguration({
            admin: admin,
            emergency: admin,
            sequencer: sequencer,
            challenger: challenger,
            prover: prover,
            preconfirmationRole: preconfirmer,
            sp1Verifier: address(sp1),
            nitroVerifier: address(0),
            bridge: bridge,
            programVKey: PROGRAM_VKEY,
            genesisHash: GENESIS_HASH,
            challengeDepositAmount: CHALLENGE_DEPOSIT,
            challengeWindow: CHALLENGE_WINDOW,
            finalizationDelay: FINALIZATION_DELAY,
            acceptDepositDeadline: DEPOSIT_DEADLINE,
            incentiveFee: 0.1 ether,
            submitBlobsWindow: SUBMIT_BLOBS_WINDOW,
            preconfirmWindow: PRECONFIRM_WINDOW,
            maxForceRevertBatchSize: MAX_FORCE_REVERT_BATCH_SIZE
        });
        Rollup impl = new Rollup();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Rollup.initialize, (abi.encode(cfg))));
        Rollup r = Rollup(address(proxy));
        vm.prank(admin);
        r.enableNitroVerifier(address(nitroVerifier));
        return r;
    }
}
