// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {FluentBridge} from "../../contracts/FluentBridge.sol";
import {RollupStorageLayout} from "../../contracts/rollup/RollupStorageLayout.sol";
import {IRollupEvents} from "../../contracts/interfaces/IRollup.sol";
import {IFluentBridgeEvents} from "../../contracts/interfaces/IFluentBridge.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";

import {MockNitroVerifier} from "./mocks/MockNitroVerifier.sol";
import {MockSp1Verifier} from "./mocks/MockSp1Verifier.sol";

/// @dev Base contract for all Rollup tests. Provides deployment, actors,
///      lifecycle action helpers, event expectation helpers, and state assertion helpers.
///      No assertions are made in this contract — only setup and utility functions.
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
    FluentBridge internal bridge;
    MockNitroVerifier internal nitroVerifier;

    // ============ Constants ============

    bytes32 internal constant GENESIS_HASH = keccak256("genesis");
    bytes32 internal constant PROGRAM_VKEY = keccak256("vkey");
    bytes32 internal constant DUMMY_SIGNATURE = keccak256("signature");

    /// @dev keccak256("") — used as the sentinel for "no messages" in block commitments
    bytes32 internal constant ZERO_BYTES_HASH = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    uint256 internal constant BATCH_SIZE = 4;
    uint256 internal constant CHALLENGE_DEPOSIT = 1 ether;
    /// @dev Ordering constraint: DA < PRECONFIRM < APPROVE, so the challenge window
    ///      (APPROVE - PRECONFIRM) is always positive after worst-case preconfirmation.
    ///      CHALLENGE is independent — it's measured from challenge creation, not acceptance.
    uint256 internal constant DA_DEADLINE_BLOCKS = 50;
    uint256 internal constant PRECONFIRM_DEADLINE_BLOCKS = 100;
    uint256 internal constant APPROVE_BLOCK_COUNT = 200;
    uint256 internal constant CHALLENGE_BLOCK_COUNT = 150;

    // ============ Setup ============

    function setUp() public virtual {
        bridge = _deployBridge();
        rollup = _deployRollup(address(bridge));
        nitroVerifier = new MockNitroVerifier();

        // wire bridge → rollup so deposits can be enqueued and popped
        vm.prank(admin);
        bridge.setRollup(address(rollup));

        // enable the mock nitro verifier
        vm.prank(admin);
        rollup.setNitroVerifier(address(nitroVerifier));
    }

    function _deployBridge() internal returns (FluentBridge) {
        FluentBridge impl = new FluentBridge();
        FluentBridge.InitConfiguration memory params = FluentBridge.InitConfiguration({
            initialOwner: admin,
            bridgeAuthority: makeAddr("bridgeAuthority"),
            rollup: address(0),
            receiveMessageDeadline: 0,
            otherBridge: makeAddr("otherBridge"),
            l1BlockOracle: address(0)
        });
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(FluentBridge.initialize, (abi.encode(params)))
        );
        return FluentBridge(payable(address(proxy)));
    }

    function _deployRollup(address bridgeAddr) internal returns (Rollup) {
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
            bridge: bridgeAddr,
            acceptDepositDeadline: 1000,
            incentiveFee: 0.1 ether,
            challenger: challenger,
            prover: prover,
            nitroVerifier: address(0),
            preconfirmationRole: preconfirmer,
            daDeadlineBlocks: DA_DEADLINE_BLOCKS,
            preconfirmDeadlineBlocks: PRECONFIRM_DEADLINE_BLOCKS
        });

        Rollup impl = new Rollup();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(Rollup.initialize, (abi.encode(cfg)))
        );

        return Rollup(address(proxy));
    }

    // ============ Batch Construction Helpers ============

    /// @dev Build a minimal valid batch of BATCH_SIZE blocks chained from parentHash. No messages.
    function _makeBatch(bytes32 parentHash) internal pure returns (RollupStorageLayout.BlockCommitment[] memory batch) {
        batch = new RollupStorageLayout.BlockCommitment[](BATCH_SIZE);
        bytes32 prev = parentHash;
        for (uint256 i = 0; i < BATCH_SIZE; i++) {
            bytes32 blockHash = keccak256(abi.encode("block", i, prev));
            batch[i] = RollupStorageLayout.BlockCommitment({
                previousBlockHash: prev,
                blockHash: blockHash,
                sentMessageRoot: ZERO_BYTES_HASH,
                receivedMessageRoot: ZERO_BYTES_HASH,
                receivedMessageCount: 0
            });
            prev = blockHash;
        }
    }

    /// @dev Build a batch where the last block contains deposits and withdrawals.
    ///      receivedMessageRoot = keccak256(abi.encodePacked(depositHashes))
    ///      sentMessageRoot = calculateMerkleRoot over withdrawalHashes
    function _makeBatchWithDeposits(
        bytes32 parentHash,
        bytes32[] memory depositHashes,
        bytes32[] memory withdrawalHashes
    ) internal pure returns (RollupStorageLayout.BlockCommitment[] memory batch) {
        batch = new RollupStorageLayout.BlockCommitment[](BATCH_SIZE);
        bytes32 prev = parentHash;

        // first BATCH_SIZE-1 blocks: empty
        for (uint256 i = 0; i < BATCH_SIZE - 1; i++) {
            bytes32 blockHash = keccak256(abi.encode("block", i, prev));
            batch[i] = RollupStorageLayout.BlockCommitment({
                previousBlockHash: prev,
                blockHash: blockHash,
                sentMessageRoot: ZERO_BYTES_HASH,
                receivedMessageRoot: ZERO_BYTES_HASH,
                receivedMessageCount: 0
            });
            prev = blockHash;
        }

        // last block: contains deposits and withdrawals
        bytes32 receivedRoot = depositHashes.length > 0
            ? keccak256(abi.encodePacked(depositHashes))
            : ZERO_BYTES_HASH;

        bytes32 sentRoot = withdrawalHashes.length > 0
            ? _computeMerkleRoot(withdrawalHashes)
            : ZERO_BYTES_HASH;

        bytes32 lastBlockHash = keccak256(abi.encode("block", BATCH_SIZE - 1, prev));
        batch[BATCH_SIZE - 1] = RollupStorageLayout.BlockCommitment({
            previousBlockHash: prev,
            blockHash: lastBlockHash,
            sentMessageRoot: sentRoot,
            receivedMessageRoot: receivedRoot,
            receivedMessageCount: depositHashes.length
        });
    }

    /// @dev Send a deposit via bridge.sendMessage and return the message hash.
    function _sendDeposit(address to, uint256 value) internal returns (bytes32 messageHash) {
        vm.deal(user, value);
        vm.prank(user);
        bridge.sendMessage{value: value}(to, "");

        uint256 nonce = bridge.nonce() - 1;
        messageHash = keccak256(
            abi.encode(user, to, value, block.chainid, block.number, nonce, bytes(""))
        );
    }

    // ============ Lifecycle Action Helpers ============

    /// @dev Accept the next batch as sequencer. Returns the batch index used.
    function _acceptBatch(bytes32 parentHash, uint256 expectedBlobs) internal returns (uint256 batchIndex) {
        batchIndex = rollup.nextBatchIndex();
        RollupStorageLayout.BlockCommitment[] memory batch = _makeBatch(parentHash);
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, expectedBlobs);
    }

    /// @dev Submit DA proof for a batch as sequencer.
    function _submitDAProof(uint256 batchIndex, uint256 numBlobs) internal {
        vm.prank(sequencer);
        rollup.submitDAProof(batchIndex, numBlobs);
    }

    /// @dev Pre-confirm a batch as preconfirmer via mock Nitro verifier.
    function _preconfirmBatch(uint256 batchIndex) internal {
        vm.prank(preconfirmer);
        rollup.commitPreConfirmation(address(nitroVerifier), batchIndex, DUMMY_SIGNATURE);
    }

    /// @dev Finalize a batch (permissionless call, no prank needed).
    function _finalizeBatch(uint256 batchIndex) internal returns (bool) {
        return rollup.ensureBatchFinalized(batchIndex);
    }

    /// @dev Challenge a block commitment as challenger. Sends CHALLENGE_DEPOSIT ETH.
    function _challengeCommitment(
        uint256 batchIndex,
        RollupStorageLayout.BlockCommitment memory commitment,
        MerkleTree.MerkleProof memory blockProof
    ) internal {
        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.prank(challenger);
        rollup.challengeBlockCommitment{value: CHALLENGE_DEPOSIT}(batchIndex, commitment, blockProof);
    }

    // ============ Event Assertion Helpers ============

    /// @dev Expect BatchAccepted event before the next action.
    function _expectBatchAccepted(uint256 batchIndex, bytes32 batchRoot) internal {
        vm.expectEmit(false, false, false, true, address(rollup));
        emit BatchAccepted(batchIndex, batchRoot);
    }

    /// @dev Expect BatchDAReady event before the next action.
    function _expectBatchDAReady(uint256 batchIndex) internal {
        vm.expectEmit(true, false, false, false, address(rollup));
        emit BatchDAReady(batchIndex);
    }

    /// @dev Expect BatchPreConfirmed event before the next action.
    function _expectBatchPreConfirmed(uint256 batchIndex) internal {
        vm.expectEmit(false, false, false, true, address(rollup));
        emit BatchPreConfirmed(batchIndex);
    }

    /// @dev Expect BatchFinalized event before the next action.
    function _expectBatchFinalized(uint256 batchIndex) internal {
        vm.expectEmit(false, false, false, true, address(rollup));
        emit BatchFinalized(batchIndex);
    }

    /// @dev Expect BatchCorrupted event before the next action.
    function _expectBatchCorrupted(uint256 batchIndex) internal {
        vm.expectEmit(true, false, false, false, address(rollup));
        emit BatchCorrupted(batchIndex);
    }

    // ============ State Assertion Helpers ============

    /// @dev Assert all BatchRecord fields in one call.
    function _assertBatchRecord(
        uint256 batchIndex,
        RollupStorageLayout.BatchStatus status,
        uint256 expBlobs,
        bytes32 batchRoot
    ) internal view {
        assertEq(uint8(rollup.batchStatus(batchIndex)), uint8(status), "batch status mismatch");
        assertEq(rollup.expectedBlobs(batchIndex), expBlobs, "expectedBlobs mismatch");
        assertEq(rollup.acceptedBatchRoot(batchIndex), batchRoot, "batchRoot mismatch");
    }

    /// @dev Assert batchBlobHashes contents match expected.
    function _assertBlobHashes(uint256 batchIndex, bytes32[] memory expected) internal view {
        bytes32[] memory actual = rollup.batchBlobHashes(batchIndex);
        assertEq(actual.length, expected.length, "blobHashes length mismatch");
        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(actual[i], expected[i], "blobHash mismatch");
        }
    }

    /// @dev Assert rollup is in corrupted state.
    function _assertRollupCorrupted() internal view {
        assertTrue(rollup.rollupCorrupted(), "expected rollup to be corrupted");
    }

    /// @dev Assert rollup is healthy (not corrupted).
    function _assertRollupHealthy() internal view {
        assertFalse(rollup.rollupCorrupted(), "expected rollup to be healthy");
    }

    /// @dev Assert a challenge exists for the given commitment hash.
    function _assertChallengeExists(bytes32 commitmentHash) internal view {
        assertTrue(rollup.provenBlockCommitment(commitmentHash) == false, "commitment should not be proven");
    }

    /// @dev Assert a challenge has been resolved (commitment proven).
    function _assertChallengeResolved(bytes32 commitmentHash) internal view {
        assertTrue(rollup.provenBlockCommitment(commitmentHash), "commitment should be proven");
    }

    /// @dev Assert challenger has expected withdrawable amount.
    function _assertChallengerWithdrawable(address _challenger, uint256 expected) internal view {
        assertEq(rollup.challengerReadyForWithdrawal(_challenger), expected, "challenger withdrawable mismatch");
    }

    /// @dev Assert prover has expected withdrawable amount.
    function _assertProverWithdrawable(address _prover, uint256 expected) internal view {
        assertEq(rollup.proverReadyForWithdrawal(_prover), expected, "prover withdrawable mismatch");
    }

    /// @dev Assert the last finalized batch index.
    function _assertLastFinalizedBatchIndex(uint256 expected) internal view {
        assertTrue(rollup.alreadyApprovedBatch(expected), "expected batch to be finalized");
        if (expected > 0) {
            // batch before should also be finalized (sequential invariant)
            assertTrue(rollup.alreadyApprovedBatch(expected), "sequential finalization broken");
        }
    }

    // ============ Negative Path Helper ============

    /// @dev Expect a revert with the given error selector on the next call.
    function _expectRevert(bytes4 selector) internal {
        vm.expectRevert(selector);
    }

    // ============ Internal Helpers ============

    /// @dev Compute a Merkle root from an array of leaf hashes.
    ///      Mirrors the algorithm in RollupStorageLayout._calculateMerkleRoot.
    function _computeMerkleRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        uint256 count = leaves.length;
        require(count > 0, "no leaves");

        bytes32[] memory layer = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            layer[i] = leaves[i];
        }

        while (count > 1) {
            uint256 nextCount = (count + 1) / 2;
            bytes32[] memory next = new bytes32[](nextCount);
            for (uint256 i = 0; i < count / 2; i++) {
                next[i] = keccak256(abi.encodePacked(layer[i * 2], layer[i * 2 + 1]));
            }
            if (count % 2 == 1) {
                next[nextCount - 1] = keccak256(abi.encodePacked(layer[count - 1], layer[count - 1]));
            }
            layer = next;
            count = nextCount;
        }

        return layer[0];
    }

    /// @dev Compute the batch root from block commitments (mirrors calculateBatchRoot).
    function _computeBatchRoot(
        RollupStorageLayout.BlockCommitment[] memory commitments
    ) internal pure returns (bytes32) {
        bytes32[] memory leaves = new bytes32[](commitments.length);
        for (uint256 i = 0; i < commitments.length; i++) {
            leaves[i] = keccak256(
                abi.encodePacked(
                    commitments[i].previousBlockHash,
                    commitments[i].blockHash,
                    commitments[i].sentMessageRoot,
                    commitments[i].receivedMessageRoot
                )
            );
        }
        return _computeMerkleRoot(leaves);
    }
}
