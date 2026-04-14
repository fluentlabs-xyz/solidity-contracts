// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {RollupAssertions} from "./Base.t.sol";
import {L2BlockHeader, BlockDeposit, BatchStatus} from "../../contracts/interfaces/IRollupTypes.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract AcceptBatchTest is RollupAssertions {
    // ============ Happy path ============

    function test_commitBatch_setsStatusToCommitted() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        bytes32 expectedRoot = _computeBatchRoot(batch);

        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);

        _assertBatchRecord(batchIndex, BatchStatus.Committed, 1, expectedRoot);
        assertEq(rollup.getBatch(batchIndex).acceptedAtBlock, block.number, "acceptedAtBlock mismatch");
    }

    function test_commitBatch_incrementsNextBatchIndex() public {
        uint256 before = rollup.nextBatchIndex();
        _acceptBatch(GENESIS_HASH, 0);
        assertEq(rollup.nextBatchIndex(), before + 1, "nextBatchIndex should increment by 1");
    }

    function test_commitBatch_emitsBatchCommitted() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        bytes32 expectedRoot = _computeBatchRoot(batch);
        uint256 batchIndex = rollup.nextBatchIndex();

        _expectBatchCommitted(batchIndex, expectedRoot, batch[batch.length - 1].blockHash, uint24(batch.length), 1);
        _acceptBatch(GENESIS_HASH, 0);
    }

    function test_commitBatch_emitsLastBlockHashInEvent() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        bytes32 expectedRoot = _computeBatchRoot(batch);
        bytes32 expectedLastHash = batch[batch.length - 1].blockHash;
        uint256 batchIndex = rollup.nextBatchIndex();

        _expectBatchCommitted(batchIndex, expectedRoot, expectedLastHash, uint24(batch.length), 1);
        _acceptBatch(GENESIS_HASH, 0);
    }

    function test_commitBatch_multipleBatchesIncrement() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        uint256 batch2 = _acceptBatch(GENESIS_HASH, 0);
        assertEq(batch2, batch1 + 1, "second batch index should follow first");

        _assertBatchRecord(batch1, BatchStatus.Committed, 1, rollup.getBatch(batch1).batchRoot);
        _assertBatchRecord(batch2, BatchStatus.Committed, 1, rollup.getBatch(batch2).batchRoot);
    }

    function test_commitBatch_fullLifecycle() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        bytes32 expectedRoot = _computeBatchRoot(batch);

        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        _assertBatchRecord(batchIndex, BatchStatus.Committed, 1, expectedRoot);

        _submitBlobs(batchIndex, 0);
        _assertBatchRecord(batchIndex, BatchStatus.Submitted, 1, expectedRoot);

        _preconfirmBatch(batchIndex);
        _assertBatchRecord(batchIndex, BatchStatus.Preconfirmed, 1, expectedRoot);

        vm.roll(block.number + FINALIZATION_DELAY + 1);
        assertTrue(_finalizeBatch(batchIndex), "batch should finalize");
        _assertBatchRecord(batchIndex, BatchStatus.Finalized, 1, expectedRoot);
        _assertLastFinalizedBatchIndex(batchIndex);
    }

    // ============ Revert tests ============

    function test_RevertIf_commitBatch_callerNotSequencer() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        bytes32 batchRoot = _computeBatchRoot(batch);
        BlockDeposit[] memory emptyDeposits = new BlockDeposit[](0);

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, rollup.SEQUENCER_ROLE()));
        vm.prank(user);
        rollup.commitBatch(batchRoot, batch[batch.length - 1].blockHash, uint24(batch.length), emptyDeposits, 1);
    }

    function test_RevertIf_commitBatch_rollupCorrupted() public {
        _acceptBatch(GENESIS_HASH, 0);
        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);
        _assertRollupCorrupted();

        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        bytes32 batchRoot = _computeBatchRoot(batch);
        BlockDeposit[] memory emptyDeposits = new BlockDeposit[](0);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(sequencer);
        rollup.commitBatch(batchRoot, batch[batch.length - 1].blockHash, uint24(batch.length), emptyDeposits, 1);
    }

    function test_RevertIf_commitBatch_zeroBatchRoot() public {
        BlockDeposit[] memory emptyDeposits = new BlockDeposit[](0);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchRoot.selector, bytes32(0), bytes32(0)));
        vm.prank(sequencer);
        rollup.commitBatch(bytes32(0), keccak256("last"), 1, emptyDeposits, 1);
    }

    function test_RevertIf_commitBatch_zeroLastBlockHash() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        bytes32 batchRoot = _computeBatchRoot(batch);
        BlockDeposit[] memory emptyDeposits = new BlockDeposit[](0);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroValueNotAllowed.selector, "lastBlockHash"));
        vm.prank(sequencer);
        rollup.commitBatch(batchRoot, bytes32(0), uint24(batch.length), emptyDeposits, 1);
    }

    function test_RevertIf_commitBatch_zeroNumberOfBlocks() public {
        BlockDeposit[] memory emptyDeposits = new BlockDeposit[](0);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroValueNotAllowed.selector, "numberOfBlocks"));
        vm.prank(sequencer);
        rollup.commitBatch(keccak256("root"), keccak256("last"), 0, emptyDeposits, 1);
    }

    function test_RevertIf_commitBatch_paused() public {
        vm.prank(admin);
        rollup.pause();

        BlockDeposit[] memory emptyDeposits = new BlockDeposit[](0);

        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vm.prank(sequencer);
        rollup.commitBatch(keccak256("root"), keccak256("last"), 1, emptyDeposits, 1);
    }

    function test_RevertIf_commitBatch_zeroDepositRootWithNonZeroCount() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        bytes32 batchRoot = _computeBatchRoot(batch);

        BlockDeposit[] memory deposits = new BlockDeposit[](1);
        deposits[0] = BlockDeposit({depositRoot: ZERO_BYTES_HASH, depositCount: 7});

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidDepositRootWithNonZeroCount.selector, uint256(7)));
        vm.prank(sequencer);
        rollup.commitBatch(batchRoot, batch[batch.length - 1].blockHash, uint24(batch.length), deposits, 1);
    }

    function test_RevertIf_acceptNextBatch_zeroExpectedBlobsCount() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroValueNotAllowed.selector, "expectedBlobsCount"));
        vm.prank(sequencer);
        rollup.commitBatch(_computeBatchRoot(batch), batch[batch.length - 1].blockHash, uint24(batch.length), new BlockDeposit[](0), 0);
    }
}
