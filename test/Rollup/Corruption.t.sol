// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {RollupAssertions} from "./Base.t.sol";
import {L2BlockHeader, BatchStatus, InitConfiguration} from "../../contracts/interfaces/IRollupTypes.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockSp1Verifier} from "../mocks/MockSp1Verifier.sol";

contract CorruptionTest is RollupAssertions {
    // ============ DA deadline ============

    function test_corrupt_daDeadlineExceeded() public {
        Rollup r = _deployRollupWithConfig(50, 0);

        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        vm.prank(sequencer);
        r.acceptNextBatch(batch, 1);

        vm.roll(block.number + 51);

        assertTrue(r.isRollupCorrupted());
    }

    function test_corrupt_daDeadlineDisabled_zeroMeansDisabled() public {
        Rollup r = _deployRollupWithConfig(0, 0);

        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        vm.prank(sequencer);
        r.acceptNextBatch(batch, 1);

        vm.roll(block.number + 1000);

        assertFalse(r.isRollupCorrupted());
    }

    function test_healthy_daDeadlineAtBoundary() public {
        Rollup r = _deployRollupWithConfig(50, 0);

        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        vm.prank(sequencer);
        r.acceptNextBatch(batch, 1);

        // DA corruption uses strict `>`; boundary block must remain healthy.
        vm.roll(block.number + 50);
        assertFalse(r.isRollupCorrupted());
    }

    // ============ Preconfirm deadline ============

    function test_corrupt_preconfirmDeadlineExceeded() public {
        Rollup r = _deployRollupWithConfig(0, 50);

        uint256 batchIndex = r.nextBatchIndex();
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        vm.prank(sequencer);
        r.acceptNextBatch(batch, 1);

        bytes32[] memory h1 = new bytes32[](1);
        h1[0] = keccak256(abi.encode("blob", batchIndex, uint256(0)));
        vm.blobhashes(h1);
        vm.prank(sequencer);
        r.submitBlobs(batchIndex, 1);

        vm.roll(block.number + 51);

        assertTrue(r.isRollupCorrupted());
    }

    function test_healthy_preconfirmDeadlineAtBoundary() public {
        Rollup r = _deployRollupWithConfig(0, 50);

        uint256 batchIndex = r.nextBatchIndex();
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        vm.prank(sequencer);
        r.acceptNextBatch(batch, 1);

        bytes32[] memory h = new bytes32[](1);
        h[0] = keccak256(abi.encode("blob", batchIndex, uint256(0)));
        vm.blobhashes(h);
        vm.prank(sequencer);
        r.submitBlobs(batchIndex, 1);

        // Preconfirm corruption uses strict `>`; boundary block must remain healthy.
        vm.roll(block.number + 50);
        assertFalse(r.isRollupCorrupted());
    }

    function test_corrupt_preconfirmDeadlineDisabled_zeroMeansDisabled() public {
        Rollup r = _deployRollupWithConfig(0, 0);

        uint256 batchIndex = r.nextBatchIndex();
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        vm.prank(sequencer);
        r.acceptNextBatch(batch, 1);

        bytes32[] memory h2 = new bytes32[](1);
        h2[0] = keccak256(abi.encode("blob", batchIndex, uint256(0)));
        vm.blobhashes(h2);
        vm.prank(sequencer);
        r.submitBlobs(batchIndex, 1);

        vm.roll(block.number + 1000);

        assertFalse(r.isRollupCorrupted());
    }

    // ============ Challenge deadline ============

    function test_corrupt_challengeDeadlineExceeded() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);

        uint256 batchIndex = rollup.nextBatchIndex();
        L2BlockHeader[] memory headers = _makeBatch(lastHash);
        vm.prank(sequencer);
        rollup.acceptNextBatch(headers, 1);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        vm.roll(block.number + CHALLENGE_WINDOW + 1);

        assertTrue(rollup.isRollupCorrupted());
    }

    function test_healthy_challengeDeadlineAtBoundary() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);

        uint256 batchIndex = rollup.nextBatchIndex();
        L2BlockHeader[] memory headers = _makeBatch(lastHash);
        vm.prank(sequencer);
        rollup.acceptNextBatch(headers, 1);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);
        uint256 deadline = rollup.getChallenge(_computeCommitment(headers[0])).deadline;

        // Challenge corruption uses strict `<`; exact deadline block is still healthy.
        vm.roll(deadline);
        assertFalse(rollup.isRollupCorrupted());
    }

    function test_healthy_afterChallengeResolved() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);

        uint256 batchIndex = rollup.nextBatchIndex();
        L2BlockHeader[] memory headers = _makeBatch(lastHash);
        vm.prank(sequencer);
        rollup.acceptNextBatch(headers, 1);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        vm.prank(prover);
        rollup.resolveChallenge(batchIndex, headers[0], proof, address(nitroVerifier), DUMMY_SIGNATURE, "");

        vm.roll(block.number + CHALLENGE_WINDOW + 1);

        assertFalse(rollup.isRollupCorrupted());
    }

    function test_healthy_preconfirmedWithoutChallenges_afterLongDelay() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);

        uint256 batchIndex = rollup.nextBatchIndex();
        L2BlockHeader[] memory headers = _makeBatch(lastHash);
        vm.prank(sequencer);
        rollup.acceptNextBatch(headers, 1);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        // No open challenges; corruption checks should stay healthy even after long delays.
        vm.roll(block.number + CHALLENGE_WINDOW + 1000);
        assertFalse(rollup.isRollupCorrupted());
    }

    // ============ Checks oldest non-finalized batch ============

    function test_corrupt_checksOldestNonFinalizedBatch() public {
        // Finalize batch 1 so lastFinalizedBatchIndex = 1
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);

        // Accept batch 2 — HeadersSubmitted, submit blobs window will expire
        uint256 batchIndex = rollup.nextBatchIndex();
        L2BlockHeader[] memory headers = _makeBatch(lastHash);
        vm.prank(sequencer);
        rollup.acceptNextBatch(headers, 1);

        // batch 3 also accepted — but corruption should trigger on batch 2
        bytes32 lastHash2 = rollup.lastBlockHashInBatch(batchIndex);
        L2BlockHeader[] memory headers3 = _makeBatch(lastHash2);
        vm.prank(sequencer);
        rollup.acceptNextBatch(headers3, 1);

        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);

        // Corruption checks lastFinalizedBatchIndex+1 = batch2, not batch3
        assertTrue(rollup.isRollupCorrupted());
        assertEq(rollup.lastFinalizedBatchIndex(), batch1);
    }

    // ============ Corruption blocks operations ============

    function test_corruptedBatchBlocksNewAcceptance() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);

        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);
        _assertRollupCorrupted();

        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        L2BlockHeader[] memory batch = _makeBatch(lastHash);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 1);
    }

    function test_preconfirmDeadlineCorruption() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);

        vm.roll(block.number + PRECONFIRM_WINDOW + 1);

        _assertRollupCorrupted();
    }

    function test_submitBlobs_revertsAfterDeadline() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        uint256 acceptedBlock = rollup.getBatch(batch1).acceptedAtBlock;

        vm.roll(acceptedBlock + SUBMIT_BLOBS_WINDOW + 1);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(sequencer);
        rollup.submitBlobs(batch1, 0);
    }

    function test_submitBlobs_revertsWhenCorrupted() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash1, 0);

        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);
        _assertRollupCorrupted();

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(sequencer);
        rollup.submitBlobs(batch2, 0);
    }

    function test_preconfirmBatch_revertsWhenCorrupted() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash1, 0);
        _submitBlobs(batch2, 0);

        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);
        _assertRollupCorrupted();

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(preconfirmer);
        rollup.preconfirmBatch(address(nitroVerifier), batch2, DUMMY_SIGNATURE);
    }

    function test_challengeBlock_revertsWhenCorrupted() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        L2BlockHeader[] memory batch2Commits = _makeBatch(lastHash1);
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch2Commits, 1);
        uint256 batch2 = batch1 + 1;
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);
        _assertRollupCorrupted();

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(batch2Commits, 0);
        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(challenger);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batch2, batch2Commits[0], proof);
    }

    // ============ Helpers ============

    function _deployRollupWithConfig(uint64 daDeadline, uint64 preconfirmDeadline) private returns (Rollup) {
        MockSp1Verifier sp1 = new MockSp1Verifier();
        InitConfiguration memory cfg;
        cfg.admin = admin;
        cfg.emergency = admin;
        cfg.sequencer = sequencer;
        cfg.challenger = challenger;
        cfg.prover = prover;
        cfg.preconfirmationRole = preconfirmer;
        cfg.sp1Verifier = address(sp1);
        cfg.nitroVerifier = address(0);
        cfg.bridge = bridgeAddr;
        cfg.programVKey = PROGRAM_VKEY;
        cfg.genesisHash = GENESIS_HASH;
        cfg.challengeDepositAmount = CHALLENGE_DEPOSIT;
        cfg.challengeWindow = CHALLENGE_WINDOW;
        cfg.finalizationDelay = FINALIZATION_DELAY;
        cfg.acceptDepositDeadline = 1000;
        cfg.incentiveFee = 0.1 ether;
        cfg.submitBlobsWindow = daDeadline;
        cfg.preconfirmWindow = preconfirmDeadline;
        cfg.maxForceRevertBatchSize = MAX_FORCE_REVERT_BATCH_SIZE;
        Rollup impl = new Rollup();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Rollup.initialize, (abi.encode(cfg))));
        return Rollup(address(proxy));
    }
}
