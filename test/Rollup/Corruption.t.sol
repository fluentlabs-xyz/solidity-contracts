// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RollupBase} from "./Base.t.sol";
import {L2BlockHeader, BatchStatus, InitConfiguration} from "../../contracts/interfaces/IRollupTypes.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockSp1Verifier} from "./mocks/MockSp1Verifier.sol";

contract CorruptionTest is RollupBase {
    // ============ DA deadline ============

    function test_corrupt_daDeadlineExceeded() public {
        Rollup r = _deployRollupWithConfig(50, 0);

        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        vm.prank(sequencer);
        r.acceptNextBatch(batch, 0);

        vm.roll(block.number + 51);

        assertTrue(r.isRollupCorrupted());
    }

    function test_corrupt_daDeadlineDisabled_zeroMeansDisabled() public {
        Rollup r = _deployRollupWithConfig(0, 0);

        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        vm.prank(sequencer);
        r.acceptNextBatch(batch, 0);

        vm.roll(block.number + 1000);

        assertFalse(r.isRollupCorrupted());
    }

    // ============ Preconfirm deadline ============

    function test_corrupt_preconfirmDeadlineExceeded() public {
        Rollup r = _deployRollupWithConfig(0, 50);

        uint256 batchIndex = r.nextBatchIndex();
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        vm.prank(sequencer);
        r.acceptNextBatch(batch, 0);

        vm.prank(sequencer);
        r.submitBlobs(batchIndex, 0);

        vm.roll(block.number + 51);

        assertTrue(r.isRollupCorrupted());
    }

    function test_corrupt_preconfirmDeadlineDisabled_zeroMeansDisabled() public {
        Rollup r = _deployRollupWithConfig(0, 0);

        uint256 batchIndex = r.nextBatchIndex();
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        vm.prank(sequencer);
        r.acceptNextBatch(batch, 0);

        vm.prank(sequencer);
        r.submitBlobs(batchIndex, 0);

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
        rollup.acceptNextBatch(headers, 0);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        vm.roll(block.number + CHALLENGE_WINDOW + 1);

        assertTrue(rollup.isRollupCorrupted());
    }

    function test_healthy_afterChallengeResolved() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);

        uint256 batchIndex = rollup.nextBatchIndex();
        L2BlockHeader[] memory headers = _makeBatch(lastHash);
        vm.prank(sequencer);
        rollup.acceptNextBatch(headers, 0);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        vm.prank(prover);
        rollup.resolveChallenge(batchIndex, headers[0], proof, address(nitroVerifier), DUMMY_SIGNATURE, "");

        vm.roll(block.number + CHALLENGE_WINDOW + 1);

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
        rollup.acceptNextBatch(headers, 0);

        // batch 3 also accepted — but corruption should trigger on batch 2
        bytes32 lastHash2 = rollup.lastBlockHashInBatch(batchIndex);
        L2BlockHeader[] memory headers3 = _makeBatch(lastHash2);
        vm.prank(sequencer);
        rollup.acceptNextBatch(headers3, 0);

        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);

        // Corruption checks lastFinalizedBatchIndex+1 = batch2, not batch3
        assertTrue(rollup.isRollupCorrupted());
        assertEq(rollup.lastFinalizedBatchIndex(), batch1);
    }

    // ============ Helpers ============

    function _deployRollupWithConfig(uint64 daDeadline, uint64 preconfirmDeadline) private returns (Rollup) {
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
            bridge: bridgeAddr,
            programVKey: PROGRAM_VKEY,
            genesisHash: GENESIS_HASH,
            challengeDepositAmount: CHALLENGE_DEPOSIT,
            challengeWindow: CHALLENGE_WINDOW,
            finalizationDelay: FINALIZATION_DELAY,
            acceptDepositDeadline: 1000,
            incentiveFee: 0.1 ether,
            submitBlobsWindow: daDeadline,
            preconfirmWindow: preconfirmDeadline
        });
        Rollup impl = new Rollup();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Rollup.initialize, (abi.encode(cfg))));
        return Rollup(address(proxy));
    }
}
