// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {RollupBase} from "./Base.t.sol";

contract RollupVerifierProofTest is RollupBase {
    bytes internal constant VALID_ZK_PROOF =
        hex"11b6a09d04e5edb1f55a53f6739a6934d3afb512e89bc5074501f23bfe46114230aa869a2887f02ef2817aff64d87d334c62a0e06a2dba798d8aaecde83e8c5ad0ddd9780433b562d8fb68f3fc43c0fa330f7400d07a87a06b62a487eb04ace591d616342d713a0a1cb4f856d2ed16dd14181adcc1516fb1f817676f3a58fd249e46bb78076291c99809d829eb9f9a34cd35eb5410eb49e45e1fa5839ecb574c4a758d8b122afd35de775bf41a3daa732a095b09beaa9648da9340a81b55574395f8829918327d8ff67bdd5ea02a778c4f252ee8a87b1b99fba0365843d581823e41a1d52dc64f4a5b2bba4190a6074a89d52e51b4f06c661963a9aae976c1550a5821fa";

    function setUp() public {
        _deploySp1RollupForVerifierPath();
    }

    function test_acceptChallengeAndProve_withSp1Verifier() public {
        Rollup.BlockCommitment[] memory batch = new Rollup.BlockCommitment[](1);
        bytes32 blockHash = 0x931c2be30add0b25a64c8b07103fe5ffdab5b58d0ca095c9e6259bfe740fff13;
        batch[0] = _buildCommitment(SP1_GENESIS_HASH, blockHash, ZERO_HASH, ZERO_HASH);

        assertEq(rollup.acceptedBatch(1), false, "batch should not be accepted yet");

        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(1, batch, new Rollup.DepositsInBlock[](0));

        assertEq(rollup.nextBatchIndex(), 2, "nextBatchIndex should be incremented");
        assertEq(rollup.acceptedBatch(1), true, "batch should be accepted");
        assertEq(rollup.lastBlockHashInBatch(1), blockHash, "last block hash should match commitment");

        bytes32 commitmentHash = _commitmentHash(batch[0]);
        MerkleTree.MerkleProof memory blockProof = _proofForSingleLeaf();

        vm.deal(CHALLENGER, 10000);
        vm.prank(CHALLENGER);
        rollup.challengeBlockCommitment{value: 10000}(1, batch[0], blockProof);

        vm.prank(PROOF_PROVIDER);
        rollup.proofBlockCommitment(1, batch[0], VALID_ZK_PROOF, blockProof);

        bytes32[] memory challengeQueue = rollup.getChallengeQueue();
        assertEq(challengeQueue.length, 0, "challenge queue must be empty");
        assertEq(rollup.provenBlockCommitment(commitmentHash), true, "commitment should be marked proven");
    }
}
