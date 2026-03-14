// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Tests in this file describe correct expected behavior.
// They FAIL with the current code and PASS after bugs are fixed.

import {RollupBase} from "./Base.t.sol";
import {RollupStorageLayout} from "../../contracts/rollup/RollupStorageLayout.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockSp1Verifier} from "./mocks/MockSp1Verifier.sol";
import {MockNitroVerifier} from "./mocks/MockNitroVerifier.sol";

contract CorruptionTest is RollupBase {
    /// @dev Verifies that the challenge queue surfaces the challenge with the earliest
    ///      deadline, regardless of insertion order or batch index.
    ///
    ///      Bug: Heap.sol uses $.challengeBatchIndex as its priority mapping, but
    ///      challengeBatchIndex is never written — all priorities are 0. The heap
    ///      degenerates to insertion-order (FIFO). With monotonic block numbers and
    ///      constant CHALLENGE_BLOCK_COUNT, FIFO happens to equal deadline order,
    ///      masking the bug. This test verifies the correct behavior: after two
    ///      challenges, rolling past the earlier deadline triggers corruption.
    ///
    ///      With the current code this test FAILS because _rollupCorrupted() enters
    ///      the Challenged branch only for the batch at lastFinalizedBatchIndex + 1,
    ///      but peeks the GLOBAL challenge queue — which may return a commitment from
    ///      a different batch. The fix must ensure the heap is ordered by actual
    ///      challenge deadline so peek always returns the earliest-expiring challenge.
    function test_heapOrderedByDeadline() public {
        // ── 1. Finalize batch 1 so lastFinalizedBatchIndex = 1 ──
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitDAProof(batch1, 0);
        _preconfirmBatch(batch1);
        vm.roll(block.number + APPROVE_BLOCK_COUNT + 1);
        assertTrue(_finalizeBatch(batch1));

        // ── 2. Accept + DA + preconfirm batch 2 ──
        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        RollupStorageLayout.BlockCommitment[] memory batch2Commits = _makeBatch(lastHash1);
        bytes32 batch2Root = _computeBatchRoot(batch2Commits);
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch2Commits, 0);
        uint256 batch2Idx = batch1 + 1;
        _submitDAProof(batch2Idx, 0);
        _preconfirmBatch(batch2Idx);

        // ── 3. Challenge a commitment in batch 2 ──
        MerkleTree.MerkleProof memory proof2 = _buildMerkleProof(batch2Commits, 0);
        _challengeCommitment(batch2Idx, batch2Commits[0], proof2);

        // ── 4. Advance 20 blocks so the next challenge gets a later deadline ──
        vm.roll(block.number + 20);

        // ── 5. Accept + DA + preconfirm batch 3 ──
        bytes32 lastHash2 = rollup.lastBlockHashInBatch(batch2Idx);
        RollupStorageLayout.BlockCommitment[] memory batch3Commits = _makeBatch(lastHash2);
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch3Commits, 0);
        uint256 batch3Idx = batch2Idx + 1;
        _submitDAProof(batch3Idx, 0);
        _preconfirmBatch(batch3Idx);

        // ── 6. Challenge a commitment in batch 3 (later block → later deadline) ──
        MerkleTree.MerkleProof memory proof3 = _buildMerkleProof(batch3Commits, 0);
        _challengeCommitment(batch3Idx, batch3Commits[0], proof3);

        // Verify the timeline: batch 3 was accepted after the vm.roll(+20)
        uint256 batch3AcceptedBlock = rollup.acceptedBlock(batch3Idx);
        assertTrue(batch3AcceptedBlock > rollup.acceptedBlock(batch2Idx), "batch3 should be accepted later");

        // ── 7. Roll past all challenge deadlines ──
        // Both challenges' deadlines are <= batch3AcceptedBlock + CHALLENGE_BLOCK_COUNT.
        // Rolling past this guarantees the earliest-deadline challenge has expired.
        vm.roll(batch3AcceptedBlock + CHALLENGE_BLOCK_COUNT + 1);

        // ── 8. Rollup should be corrupted ──
        // batch 2 is at lastFinalizedBatchIndex + 1, status = Challenged.
        // The heap should surface the challenge with the earliest deadline (batch 2's).
        _assertRollupCorrupted();
    }

    /// @dev Verifies that daDeadlineBlocks = 0 means "disabled" (no deadline
    ///      enforcement), not "zero-block deadline" (immediate corruption).
    ///
    ///      Bug: submitDAProof skips the check when daDeadlineBlocks == 0 (treats
    ///      0 as disabled), but _rollupCorrupted checks:
    ///        block.number > accepted + daDeadlineBlocks
    ///      When daDeadlineBlocks == 0 this becomes block.number > acceptedBlock,
    ///      which is always true — corrupting the rollup immediately after any
    ///      batch is accepted.
    function test_zeroDeadlineMeansDisabled() public {
        Rollup r = _deployRollupWithConfig(0, 0);

        // Accept a batch
        RollupStorageLayout.BlockCommitment[] memory batch = _makeBatch(GENESIS_HASH);
        vm.prank(sequencer);
        r.acceptNextBatch(batch, 0);

        // Roll one block
        vm.roll(block.number + 1);

        // Rollup should NOT be corrupted — 0 means disabled
        assertFalse(r.rollupCorrupted(), "daDeadlineBlocks=0 should mean disabled, not immediate corruption");
    }

    // ============ Private Helpers ============

    /// @dev Deploy a rollup with custom deadline config, wired to the shared bridge.
    function _deployRollupWithConfig(
        uint64 daDeadline,
        uint64 preconfirmDeadline
    ) private returns (Rollup) {
        MockSp1Verifier sp1 = new MockSp1Verifier();

        RollupStorageLayout.InitConfiguration memory cfg = RollupStorageLayout.InitConfiguration({
            admin: admin,
            sequencer: sequencer,
            pauser: admin,
            challengeDepositAmount: CHALLENGE_DEPOSIT,
            challengeBlockCount: CHALLENGE_BLOCK_COUNT,
            approveBlockCount: APPROVE_BLOCK_COUNT,
            sp1Verifier: address(sp1),
            programVKey: PROGRAM_VKEY,
            genesisHash: GENESIS_HASH,
            bridge: address(bridge),
            acceptDepositDeadline: 1000,
            incentiveFee: 0.1 ether,
            challenger: challenger,
            prover: prover,
            nitroVerifier: address(0),
            preconfirmationRole: preconfirmer,
            daDeadlineBlocks: daDeadline,
            preconfirmDeadlineBlocks: preconfirmDeadline
        });

        Rollup impl = new Rollup();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(Rollup.initialize, (abi.encode(cfg)))
        );

        Rollup r = Rollup(address(proxy));

        vm.prank(admin);
        r.setNitroVerifier(address(nitroVerifier));

        return r;
    }

    /// @dev Build a Merkle proof for the commitment at `leafIndex` within a batch.
    ///      Mirrors the tree built by calculateBatchRoot.
    function _buildMerkleProof(
        RollupStorageLayout.BlockCommitment[] memory commitments,
        uint256 leafIndex
    ) internal pure returns (MerkleTree.MerkleProof memory) {
        uint256 count = commitments.length;
        bytes32[] memory leaves = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            leaves[i] = keccak256(
                abi.encodePacked(
                    commitments[i].previousBlockHash,
                    commitments[i].blockHash,
                    commitments[i].sentMessageRoot,
                    commitments[i].receivedMessageRoot
                )
            );
        }

        // Build proof by collecting siblings at each level
        bytes memory proofData;
        uint256 idx = leafIndex;

        while (count > 1) {
            uint256 nextCount = (count + 1) / 2;
            bytes32[] memory nextLeaves = new bytes32[](nextCount);

            for (uint256 i = 0; i < count / 2; i++) {
                nextLeaves[i] = keccak256(abi.encodePacked(leaves[i * 2], leaves[i * 2 + 1]));
            }
            if (count % 2 == 1) {
                nextLeaves[nextCount - 1] = keccak256(abi.encodePacked(leaves[count - 1], leaves[count - 1]));
            }

            // Sibling of idx
            uint256 siblingIdx = (idx % 2 == 0) ? idx + 1 : idx - 1;
            bytes32 sibling;
            if (siblingIdx < count) {
                sibling = leaves[siblingIdx];
            } else {
                // Odd leaf, paired with itself
                sibling = leaves[idx];
            }
            proofData = abi.encodePacked(proofData, sibling);

            idx = idx / 2;
            leaves = nextLeaves;
            count = nextCount;
        }

        return MerkleTree.MerkleProof({nonce: leafIndex, proof: proofData});
    }
}
