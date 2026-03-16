// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {IRollupEvents, IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {L2BlockHeader, BatchStatus, BatchRecord, InitConfiguration} from "../../contracts/interfaces/IRollupTypes.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";

import {MockNitroVerifier} from "./mocks/MockNitroVerifier.sol";
import {MockSp1Verifier} from "./mocks/MockSp1Verifier.sol";

abstract contract RollupBase is Test, IRollupEvents {
    // ============ Actors ============

    address internal admin = makeAddr("admin");
    address internal sequencer = makeAddr("sequencer");
    address internal challenger = makeAddr("challenger");
    address internal prover = makeAddr("prover");
    address internal preconfirmer = makeAddr("preconfirmer");
    address internal user = makeAddr("user");

    // ============ Contracts ============

    Rollup internal rollup;
    address internal bridgeAddr;
    MockNitroVerifier internal nitroVerifier;

    // ============ Constants ============

    bytes32 internal constant GENESIS_HASH = keccak256("genesis");
    bytes32 internal constant PROGRAM_VKEY = keccak256("vkey");
    bytes32 internal constant DUMMY_SIGNATURE = keccak256("signature");
    /// @dev Mirrors RollupStorageLayout.ZERO_BYTES_HASH — keccak256 of empty bytes.
    bytes32 internal constant ZERO_BYTES_HASH = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    uint256 internal constant BATCH_SIZE = 4;
    uint256 internal constant CHALLENGE_DEPOSIT = 1 ether;
    uint256 internal constant SUBMIT_BLOBS_WINDOW = 50;
    uint256 internal constant PRECONFIRM_WINDOW = 100;
    uint256 internal constant FINALIZATION_DELAY = 200;
    uint256 internal constant CHALLENGE_WINDOW = 150;

    // ============ Setup ============

    function setUp() public virtual {
        bridgeAddr = makeAddr("bridge");
        nitroVerifier = new MockNitroVerifier();
        rollup = _deployRollup(bridgeAddr);
    }

    function _deployRollup(address _bridge) internal returns (Rollup) {
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
            bridge: _bridge,
            programVKey: PROGRAM_VKEY,
            genesisHash: GENESIS_HASH,
            challengeDepositAmount: CHALLENGE_DEPOSIT,
            challengeWindow: CHALLENGE_WINDOW,
            finalizationDelay: FINALIZATION_DELAY,
            acceptDepositDeadline: 1000,
            incentiveFee: 0.1 ether,
            submitBlobsWindow: SUBMIT_BLOBS_WINDOW,
            preconfirmWindow: PRECONFIRM_WINDOW
        });
        Rollup impl = new Rollup();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Rollup.initialize, (abi.encode(cfg))));
        Rollup r = Rollup(address(proxy));
        vm.prank(admin);
        r.enableNitroVerifier(address(nitroVerifier));
        return r;
    }

    // ============ Batch Construction ============

    function _makeBatch(bytes32 parentHash) internal pure returns (L2BlockHeader[] memory batch) {
        batch = new L2BlockHeader[](BATCH_SIZE);
        bytes32 prev = parentHash;
        for (uint256 i = 0; i < BATCH_SIZE; i++) {
            bytes32 blockHash = keccak256(abi.encode("block", i, prev));
            batch[i] = L2BlockHeader({
                previousBlockHash: prev,
                blockHash: blockHash,
                withdrawalRoot: ZERO_BYTES_HASH,
                depositRoot: ZERO_BYTES_HASH,
                depositCount: 0
            });
            prev = blockHash;
        }
    }

    // ============ Lifecycle Action Helpers ============

    function _acceptBatch(bytes32 parentHash, uint256 expectedBlobs) internal returns (uint256 batchIndex) {
        batchIndex = rollup.nextBatchIndex();
        L2BlockHeader[] memory batch = _makeBatch(parentHash);
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, expectedBlobs);
    }

    function _submitBlobs(uint256 batchIndex, uint256 numBlobs) internal {
        if (numBlobs > 0) {
            bytes32[] memory hashes = new bytes32[](numBlobs);
            for (uint256 i = 0; i < numBlobs; i++) {
                hashes[i] = keccak256(abi.encode("blob", batchIndex, i));
            }
            vm.blobhashes(hashes);
        }
        vm.prank(sequencer);
        rollup.submitBlobs(batchIndex, numBlobs);
    }

    function _preconfirmBatch(uint256 batchIndex) internal {
        vm.prank(preconfirmer);
        rollup.preconfirmBatch(address(nitroVerifier), batchIndex, DUMMY_SIGNATURE);
    }

    function _finalizeBatch(uint256 batchIndex) internal returns (bool) {
        return rollup.finalizeBatches(batchIndex) > 0;
    }

    function _challengeBlock(uint256 batchIndex, L2BlockHeader memory blockHeader, MerkleTree.MerkleProof memory blockProof) internal {
        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.prank(challenger);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, blockHeader, blockProof);
    }

    /// @dev expectedBlobs=0 shortcut — submitBlobs(batchIndex, 0) with expectedBlobs=0
    ///      transitions immediately to Accepted (0 submitted == 0 expected).
    function _fullyFinalizeBatch(bytes32 parentHash) internal returns (uint256 batchIndex) {
        return _fullyFinalizeBatch(parentHash, 0);
    }

    function _fullyFinalizeBatch(bytes32 parentHash, uint256 expectedBlobs) internal returns (uint256 batchIndex) {
        batchIndex = _acceptBatch(parentHash, expectedBlobs);
        _submitBlobs(batchIndex, expectedBlobs);
        _preconfirmBatch(batchIndex);
        vm.roll(block.number + FINALIZATION_DELAY + 1);
        assertTrue(_finalizeBatch(batchIndex));
    }

    // ============ Event Helpers ============

    function _expectBatchHeadersSubmitted(uint256 batchIndex, bytes32 batchRoot, uint256 expectedBlobs) internal {
        vm.expectEmit(true, false, false, true, address(rollup));
        emit BatchHeadersSubmitted(batchIndex, batchRoot, expectedBlobs);
    }

    function _expectBatchAccepted(uint256 batchIndex) internal {
        vm.expectEmit(true, false, false, false, address(rollup));
        emit BatchAccepted(batchIndex);
    }

    function _expectBatchPreconfirmed(uint256 batchIndex) internal {
        vm.expectEmit(true, false, false, false, address(rollup));
        emit BatchPreconfirmed(batchIndex);
    }

    function _expectBatchFinalized(uint256 batchIndex) internal {
        vm.expectEmit(true, false, false, false, address(rollup));
        emit BatchFinalized(batchIndex);
    }

    // ============ State Assertion Helpers ============

    function _assertBatchRecord(uint256 batchIndex, BatchStatus status, uint256 expBlobs, bytes32 batchRoot) internal view {
        BatchRecord memory batch = rollup.getBatch(batchIndex);
        assertEq(uint8(batch.status), uint8(status), "batch status mismatch");
        assertEq(batch.expectedBlobs, expBlobs, "expectedBlobs mismatch");
        assertEq(batch.batchRoot, batchRoot, "batchRoot mismatch");
    }

    function _assertRollupCorrupted() internal view {
        assertTrue(rollup.isRollupCorrupted(), "expected rollup to be corrupted");
    }

    function _assertRollupHealthy() internal view {
        assertFalse(rollup.isRollupCorrupted(), "expected rollup to be healthy");
    }

    function _assertChallengeExists(bytes32 commitment) internal view {
        assertTrue(rollup.getChallenge(commitment).challenger != address(0), "challenge should exist");
    }

    function _assertChallengeResolved(bytes32 commitment) internal view {
        assertTrue(rollup.isBlockProven(commitment), "commitment should be proven");
    }

    function _assertChallengerWithdrawable(address _challenger, uint256 expected) internal view {
        assertEq(rollup.claimableChallengerReward(_challenger), expected);
    }

    function _assertProverWithdrawable(address _prover, uint256 expected) internal view {
        assertEq(rollup.claimableProofReward(_prover), expected);
    }

    function _assertLastFinalizedBatchIndex(uint256 expected) internal view {
        assertEq(rollup.lastFinalizedBatchIndex(), expected);
    }

    // ============ Merkle Helpers ============

    function _computeBatchRoot(L2BlockHeader[] memory headers) internal pure returns (bytes32) {
        bytes memory leafs = new bytes(headers.length * 32);
        for (uint256 i = 0; i < headers.length; i++) {
            bytes32 hash = keccak256(
                abi.encodePacked(headers[i].previousBlockHash, headers[i].blockHash, headers[i].withdrawalRoot, headers[i].depositRoot)
            );
            assembly {
                mstore(add(add(leafs, 32), mul(i, 32)), hash)
            }
        }
        return MerkleTree.calculateMerkleRoot(leafs);
    }

    function _buildMerkleProof(L2BlockHeader[] memory headers, uint256 leafIndex) internal pure returns (MerkleTree.MerkleProof memory) {
        uint256 count = headers.length;
        bytes32[] memory leaves = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            leaves[i] = keccak256(
                abi.encodePacked(headers[i].previousBlockHash, headers[i].blockHash, headers[i].withdrawalRoot, headers[i].depositRoot)
            );
        }
        bytes memory proofData;
        uint256 idx = leafIndex;
        while (count > 1) {
            uint256 nextCount = (count + 1) / 2;
            bytes32[] memory next = new bytes32[](nextCount);
            for (uint256 i = 0; i < count / 2; i++) {
                next[i] = keccak256(abi.encodePacked(leaves[i * 2], leaves[i * 2 + 1]));
            }
            if (count % 2 == 1) {
                next[nextCount - 1] = keccak256(abi.encodePacked(leaves[count - 1], leaves[count - 1]));
            }
            uint256 siblingIdx = (idx % 2 == 0) ? idx + 1 : idx - 1;
            proofData = abi.encodePacked(proofData, siblingIdx < count ? leaves[siblingIdx] : leaves[idx]);
            idx = idx / 2;
            leaves = next;
            count = nextCount;
        }
        return MerkleTree.MerkleProof({nonce: leafIndex, proof: proofData});
    }

    function _computeCommitment(L2BlockHeader memory header) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(header.previousBlockHash, header.blockHash, header.withdrawalRoot, header.depositRoot));
    }
}
