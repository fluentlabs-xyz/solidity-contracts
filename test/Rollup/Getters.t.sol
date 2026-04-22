// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {L2BlockHeader, BlockDeposit, BatchStatus} from "../../contracts/interfaces/rollup/IRollupTypes.sol";
import {RollupAssertions} from "./Base.t.sol";

contract RollupGettersTest is RollupAssertions {
    function test_getters_returnInitializedConfig() public {
        assertEq(rollup.finalizationDelay(), FINALIZATION_DELAY, "finalizationDelay");
        assertEq(rollup.challengeWindow(), CHALLENGE_WINDOW, "challengeWindow");
        assertEq(rollup.challengeDepositAmount(), CHALLENGE_DEPOSIT, "challengeDepositAmount");
        assertEq(rollup.incentiveFee(), 0.1 ether, "incentiveFee");
        assertEq(rollup.submitBlobsWindow(), SUBMIT_BLOBS_WINDOW, "submitBlobsWindow");
    }

    function test_isBatchPreconfirmed_transitions() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        // Accepted, but not yet Preconfirmed.
        _submitBlobs(batchIndex, 0);
        assertFalse(rollup.isBatchPreconfirmed(batchIndex), "should not be preconfirmed yet");

        _preconfirmBatch(batchIndex);
        assertTrue(rollup.isBatchPreconfirmed(batchIndex), "should be preconfirmed now");
    }

    function test_challengeQueueLength_andAt_afterChallenge() public {
        // Create a single batch preconfirmed on L1.
        L2BlockHeader[] memory headers = _makeBatch(GENESIS_HASH);
        uint256 batchIndex = rollup.nextBatchIndex();
        vm.prank(sequencer);
        rollup.commitBatch(_computeBatchRoot(headers), GENESIS_HASH, headers[headers.length - 1].blockHash, uint24(headers.length), new BlockDeposit[](0), 1);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);
        assertTrue(rollup.isBatchPreconfirmed(batchIndex), "precondition: batch must be preconfirmed");

        // Challenge the first block header commitment.
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        bytes32 commitment = _computeCommitment(headers[0]);

        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.prank(challenger);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[0], proof);

        assertEq(rollup.blockChallengeQueueLength(), 1, "blockChallengeQueueLength");
        assertEq(rollup.blockChallengeQueueAt(0), commitment, "blockChallengeQueueAt");
    }

    function test_verifyBlockInBatch_returnsIncludedAndStatus() public {
        L2BlockHeader[] memory headers = _makeBatch(GENESIS_HASH);
        uint256 batchIndex = rollup.nextBatchIndex();
        vm.prank(sequencer);
        rollup.commitBatch(_computeBatchRoot(headers), GENESIS_HASH, headers[headers.length - 1].blockHash, uint24(headers.length), new BlockDeposit[](0), 1);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        uint256 idx = 2;
        MerkleTree.MerkleProof memory p = _buildMerkleProof(headers, idx);
        bytes memory contractProof = abi.encodePacked(headers[idx].previousBlockHash, headers[idx].withdrawalRoot, headers[idx].depositRoot, p.proof);

        (bool included, uint8 status) = rollup.verifyBlockInBatch(batchIndex, headers[idx].blockHash, p.nonce, contractProof);
        assertTrue(included, "included should be true");
        assertEq(status, uint8(BatchStatus.Preconfirmed), "status mismatch");
    }

    function test_verifyBlockInBatch_returnsFalseForWrongBlockHash() public {
        L2BlockHeader[] memory headers = _makeBatch(GENESIS_HASH);
        uint256 batchIndex = rollup.nextBatchIndex();
        vm.prank(sequencer);
        rollup.commitBatch(_computeBatchRoot(headers), GENESIS_HASH, headers[headers.length - 1].blockHash, uint24(headers.length), new BlockDeposit[](0), 1);

        MerkleTree.MerkleProof memory p = _buildMerkleProof(headers, 1);
        bytes memory contractProof = abi.encodePacked(headers[1].previousBlockHash, headers[1].withdrawalRoot, headers[1].depositRoot, p.proof);

        (bool included, uint8 status) = rollup.verifyBlockInBatch(batchIndex, keccak256("wrong-hash"), p.nonce, contractProof);
        assertFalse(included, "included should be false");
        assertEq(status, uint8(BatchStatus.Committed), "status mismatch");
    }

    function test_verifyBlockInBatch_returnsFalseForMalformedProof() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 1);
        bytes memory malformed = hex"123456";

        (bool included, uint8 status) = rollup.verifyBlockInBatch(batchIndex, bytes32(uint256(1)), 0, malformed);
        assertFalse(included, "included should be false");
        assertEq(status, uint8(BatchStatus.Committed), "status mismatch");
    }
}
