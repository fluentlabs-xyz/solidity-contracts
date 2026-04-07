// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {RollupAssertions} from "./Base.t.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {L2BlockHeader, BatchRecord, BatchStatus, InitConfiguration} from "../../contracts/interfaces/IRollupTypes.sol";
import {MockDepositBridge} from "../mocks/MockDepositBridge.sol";
import {MockNitroVerifier} from "../mocks/MockNitroVerifier.sol";
import {MockSp1Verifier} from "../mocks/MockSp1Verifier.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract RollupSnapshotTest is RollupAssertions {
    uint32 internal constant OLD_DEPOSIT_DEADLINE = 1000;

    function test_acceptNextBatch_snapshotsCurrentBatchWindows() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        BatchRecord memory batch = rollup.getBatch(batchIndex);

        assertEq(batch.submitBlobsWindowSnapshot, SUBMIT_BLOBS_WINDOW, "submitBlobs window snapshot mismatch");
        assertEq(batch.challengeWindowSnapshot, CHALLENGE_WINDOW, "challenge window snapshot mismatch");
        assertEq(batch.finalizationDelaySnapshot, FINALIZATION_DELAY, "finalization delay snapshot mismatch");
    }

    function test_submitBlobs_snapshotIgnoresLaterShorterWindow() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        uint256 acceptedAt = rollup.getBatch(batchIndex).acceptedAtBlock;

        vm.prank(admin);
        rollup.setSubmitBlobsWindow(5);

        vm.roll(acceptedAt + 6);
        assertFalse(rollup.isRollupCorrupted(), "old batch should keep original submitBlobs snapshot");

        _submitBlobs(batchIndex, 0);
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Accepted), "blob submission should still succeed");
    }

    function test_submitBlobs_snapshotUsesUpdatedValueForNewBatch() public {
        vm.prank(admin);
        rollup.setSubmitBlobsWindow(5);

        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        BatchRecord memory batch = rollup.getBatch(batchIndex);
        assertEq(batch.submitBlobsWindowSnapshot, 5, "new batch should snapshot the updated submitBlobs window");

        vm.roll(uint256(batch.acceptedAtBlock) + 6);
        assertTrue(rollup.isRollupCorrupted(), "new batch should use the shortened submitBlobs snapshot");
    }

    function test_submitBlobs_snapshotBoundaryAllowsAtExactDeadline() public {
        vm.prank(admin);
        rollup.setSubmitBlobsWindow(5);

        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        uint256 acceptedAt = rollup.getBatch(batchIndex).acceptedAtBlock;

        vm.roll(acceptedAt + 5);
        _submitBlobs(batchIndex, 0);

        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Accepted), "exact submitBlobs boundary should succeed");
    }

    function test_challengeWindow_snapshotIgnoresLaterShorterWindow() public {
        L2BlockHeader[] memory headers = _makeBatch(GENESIS_HASH);
        uint256 batchIndex = rollup.nextBatchIndex();

        vm.prank(sequencer);
        rollup.acceptNextBatch(headers, 1);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        uint256 acceptedAt = rollup.getBatch(batchIndex).acceptedAtBlock;

        vm.prank(admin);
        rollup.setChallengeWindow(10);

        vm.roll(acceptedAt + 20);

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        assertEq(rollup.getChallenge(_computeCommitment(headers[0])).deadline, acceptedAt + CHALLENGE_WINDOW, "challenge deadline should use the snapshotted window");
    }

    function test_challengeWindow_snapshotBoundaryRevertsAtExactDeadline() public {
        vm.prank(admin);
        rollup.setChallengeWindow(10);

        L2BlockHeader[] memory headers = _makeBatch(GENESIS_HASH);
        uint256 batchIndex = rollup.nextBatchIndex();

        vm.prank(sequencer);
        rollup.acceptNextBatch(headers, 1);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        uint256 acceptedAt = rollup.getBatch(batchIndex).acceptedAtBlock;
        vm.roll(acceptedAt + 10);

        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ChallengeTooLate.selector, batchIndex));
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[0], _buildMerkleProof(headers, 0));
    }

    function test_finalizationDelay_snapshotIgnoresLaterShorterDelay() public {
        vm.prank(admin);
        rollup.setChallengeWindow(5);

        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);
        uint256 acceptedAt = rollup.getBatch(batchIndex).acceptedAtBlock;

        vm.prank(admin);
        rollup.setFinalizationDelay(10);

        vm.roll(acceptedAt + 11);
        assertEq(rollup.finalizeBatches(batchIndex), 0, "old batch should keep original finalization delay snapshot");
    }

    function test_finalizationDelay_snapshotBoundaryFinalizesAfterDeadlineOnly() public {
        vm.prank(admin);
        rollup.setChallengeWindow(5);
        vm.prank(admin);
        rollup.setFinalizationDelay(10);

        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);
        uint256 acceptedAt = rollup.getBatch(batchIndex).acceptedAtBlock;

        vm.roll(acceptedAt + 10);
        assertEq(rollup.finalizeBatches(batchIndex), 0, "exact finalization boundary should not finalize");

        vm.roll(acceptedAt + 11);
        assertEq(rollup.finalizeBatches(batchIndex), 1, "batch should finalize after the snapshotted delay elapses");
    }

    function test_acceptDepositDeadline_oldQueuedDepositIgnoresLaterShorterConfig() public {
        MockDepositBridge depositBridge = new MockDepositBridge(OLD_DEPOSIT_DEADLINE);
        Rollup localRollup = _deployRollupWithBridge(address(depositBridge));

        uint256 depositQueuedAtBlock = 10;
        bytes32 depositHash = keccak256("snapshotted-deposit");
        depositBridge.enqueue(depositHash, depositQueuedAtBlock);

        depositBridge.setAcceptDepositDeadline(1);

        vm.roll(100);
        L2BlockHeader[] memory batch = _makeBatchWithDeposit(GENESIS_HASH, 0, depositHash);

        vm.prank(sequencer);
        localRollup.acceptNextBatch(batch, 1);

        assertEq(uint8(localRollup.getBatch(1).status), uint8(BatchStatus.HeadersSubmitted), "old queued deposit should honor its original absolute deadline");
    }

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

    function _deployRollupWithBridge(address bridge) internal returns (Rollup) {
        MockSp1Verifier sp1 = new MockSp1Verifier();
        MockNitroVerifier localNitroVerifier = new MockNitroVerifier();

        InitConfiguration memory cfg;
        cfg.admin = admin;
        cfg.emergency = admin;
        cfg.sequencer = sequencer;
        cfg.challenger = challenger;
        cfg.prover = prover;
        cfg.preconfirmationRole = preconfirmer;
        cfg.sp1Verifier = address(sp1);
        cfg.nitroVerifier = address(0);
        cfg.bridge = bridge;
        cfg.programVKey = PROGRAM_VKEY;
        cfg.genesisHash = GENESIS_HASH;
        cfg.challengeDepositAmount = CHALLENGE_DEPOSIT;
        cfg.challengeWindow = CHALLENGE_WINDOW;
        cfg.finalizationDelay = FINALIZATION_DELAY;
        cfg.incentiveFee = 0.1 ether;
        cfg.submitBlobsWindow = SUBMIT_BLOBS_WINDOW;
        cfg.maxDepositsPerBatch = MAX_DEPOSITS_PER_BATCH;
        cfg.maxForceRevertBatchSize = MAX_FORCE_REVERT_BATCH_SIZE;

        Rollup impl = new Rollup();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Rollup.initialize, (abi.encode(cfg))));
        Rollup localRollup = Rollup(address(proxy));
        vm.prank(admin);
        localRollup.enableNitroVerifier(address(localNitroVerifier));
        return localRollup;
    }
}
