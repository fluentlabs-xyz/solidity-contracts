// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {L2BlockHeader} from "../../contracts/interfaces/IRollupTypes.sol";
import {RollupAssertions} from "./Base.t.sol";

contract RollupGettersTest is RollupAssertions {
    function test_getters_returnInitializedConfig() public {
        assertEq(rollup.finalizationDelay(), FINALIZATION_DELAY, "finalizationDelay");
        assertEq(rollup.challengeWindow(), CHALLENGE_WINDOW, "challengeWindow");
        assertEq(rollup.challengeDepositAmount(), CHALLENGE_DEPOSIT, "challengeDepositAmount");
        assertEq(rollup.incentiveFee(), 0.1 ether, "incentiveFee");
        assertEq(rollup.acceptDepositDeadline(), 1000, "acceptDepositDeadline");
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
        rollup.acceptNextBatch(headers, 1);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);
        assertTrue(rollup.isBatchPreconfirmed(batchIndex), "precondition: batch must be preconfirmed");

        // Challenge the first block header commitment.
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        bytes32 commitment = _computeCommitment(headers[0]);

        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.prank(challenger);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[0], proof);

        assertEq(rollup.challengeQueueLength(), 1, "challengeQueueLength");
        assertEq(rollup.challengeQueueAt(0), commitment, "challengeQueueAt");
    }
}
