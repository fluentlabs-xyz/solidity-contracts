// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {RollupAssertions} from "./Base.t.sol";
import {L2BlockHeader, BatchStatus} from "../../contracts/interfaces/IRollupTypes.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract AcceptBatchTest is RollupAssertions {
    // ============ Happy path ============

    function test_acceptNextBatch_setsStatusToHeadersSubmitted() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        bytes32 expectedRoot = _computeBatchRoot(batch);

        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);

        _assertBatchRecord(batchIndex, BatchStatus.HeadersSubmitted, 1, expectedRoot);
        assertEq(rollup.getBatch(batchIndex).acceptedAtBlock, block.number, "acceptedAtBlock mismatch");
    }

    function test_acceptNextBatch_incrementsNextBatchIndex() public {
        uint256 before = rollup.nextBatchIndex();
        _acceptBatch(GENESIS_HASH, 0);
        assertEq(rollup.nextBatchIndex(), before + 1, "nextBatchIndex should increment by 1");
    }

    function test_acceptNextBatch_storesLastBlockHash() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);

        bytes32 expectedLastHash = batch[batch.length - 1].blockHash;
        assertEq(rollup.lastBlockHashInBatch(batchIndex), expectedLastHash, "lastBlockHash mismatch");
    }

    function test_acceptNextBatch_emitsBatchHeadersSubmitted() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        bytes32 expectedRoot = _computeBatchRoot(batch);
        uint256 batchIndex = rollup.nextBatchIndex();

        _expectBatchHeadersSubmitted(batchIndex, expectedRoot, 1);
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 1);
    }

    function test_acceptNextBatch_multipleBatchesChainCorrectly() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);

        uint256 batch2 = _acceptBatch(lastHash, 0);
        assertEq(batch2, batch1 + 1, "second batch index should follow first");

        _assertBatchRecord(batch1, BatchStatus.HeadersSubmitted, 1, rollup.getBatch(batch1).batchRoot);
        _assertBatchRecord(batch2, BatchStatus.HeadersSubmitted, 1, rollup.getBatch(batch2).batchRoot);
    }

    function test_acceptNextBatch_fullLifecycle() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        bytes32 expectedRoot = _computeBatchRoot(batch);

        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        _assertBatchRecord(batchIndex, BatchStatus.HeadersSubmitted, 1, expectedRoot);

        _submitBlobs(batchIndex, 0);
        _assertBatchRecord(batchIndex, BatchStatus.Accepted, 1, expectedRoot);

        _preconfirmBatch(batchIndex);
        _assertBatchRecord(batchIndex, BatchStatus.Preconfirmed, 1, expectedRoot);

        vm.roll(block.number + FINALIZATION_DELAY + 1);
        assertTrue(_finalizeBatch(batchIndex), "batch should finalize");
        _assertBatchRecord(batchIndex, BatchStatus.Finalized, 1, expectedRoot);
        _assertLastFinalizedBatchIndex(batchIndex);
    }

    // ============ Revert tests ============

    function test_RevertIf_acceptNextBatch_callerNotSequencer() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, rollup.SEQUENCER_ROLE()));
        vm.prank(user);
        rollup.acceptNextBatch(batch, 1);
    }

    function test_RevertIf_acceptNextBatch_rollupCorrupted() public {
        _acceptBatch(GENESIS_HASH, 0);
        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);
        _assertRollupCorrupted();

        bytes32 lastHash = rollup.lastBlockHashInBatch(1);
        L2BlockHeader[] memory batch = _makeBatch(lastHash);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 1);
    }

    function test_RevertIf_acceptNextBatch_emptyBatch() public {
        L2BlockHeader[] memory empty = new L2BlockHeader[](0);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.NoLeavesProvided.selector));
        vm.prank(sequencer);
        rollup.acceptNextBatch(empty, 1);
    }

    function test_RevertIf_acceptNextBatch_wrongParentHash() public {
        _acceptBatch(GENESIS_HASH, 0);

        bytes32 wrongParent = keccak256("wrong");
        L2BlockHeader[] memory batch = _makeBatch(wrongParent);
        bytes32 expectedParent = rollup.lastBlockHashInBatch(1);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.WrongPreviousBlockHash.selector, expectedParent, wrongParent));
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 1);
    }

    function test_RevertIf_acceptNextBatch_brokenBlockSequence() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        batch[1].previousBlockHash = keccak256("broken");

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBlockSequence.selector, 0, batch[0].blockHash, keccak256("broken")));
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 1);
    }

    function test_RevertIf_acceptNextBatch_zeroDepositRootWithNonZeroCount() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        batch[batch.length - 1].depositCount = 5;

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidDepositRootWithNonZeroCount.selector, uint256(5)));
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 1);
    }

    function test_RevertIf_acceptNextBatch_interiorZeroDepositRootWithNonZeroCount() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        batch[0].depositCount = 7;

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidDepositRootWithNonZeroCount.selector, uint256(7)));
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 1);
    }

    function test_RevertIf_acceptNextBatch_wrongPreviousBlockHash() public {
        L2BlockHeader[] memory batch = _makeBatch(keccak256("not-genesis"));

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.WrongPreviousBlockHash.selector, GENESIS_HASH, keccak256("not-genesis")));
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 1);
    }

    function test_RevertIf_acceptNextBatch_invalidBlockSequence() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        batch[1].previousBlockHash = keccak256("bad-link");

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBlockSequence.selector, 0, batch[0].blockHash, keccak256("bad-link")));
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 1);
    }

    function test_RevertIf_acceptNextBatch_invalidDepositRootWithNonZeroCount() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        batch[batch.length - 1].depositCount = 3;

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidDepositRootWithNonZeroCount.selector, uint256(3)));
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 1);
    }

    function test_RevertIf_acceptNextBatch_paused() public {
        vm.prank(admin);
        rollup.pause();

        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);

        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 1);
    }
}
