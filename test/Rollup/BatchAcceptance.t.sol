// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {RollupBase} from "./Base.t.sol";

contract RollupBatchAcceptanceTest is RollupBase {
    function setUp() public {
        _deployMockRollup({
            batchSize_: 2,
            challengeDepositAmount_: 10000,
            challengeBlockCount_: 1,
            approveBlockCount_: 1,
            acceptDepositDeadline_: 10,
            incentiveFee_: 0
        });
    }

    function _buildLinkedBatch(bytes32 prevHash) internal pure returns (Rollup.BlockCommitment[] memory batch) {
        batch = new Rollup.BlockCommitment[](2);
        bytes32 blockHash1 = keccak256("accept-batch-1");
        bytes32 blockHash2 = keccak256("accept-batch-2");

        batch[0] = _buildCommitment(prevHash, blockHash1, ZERO_HASH, ZERO_HASH);
        batch[1] = _buildCommitment(blockHash1, blockHash2, ZERO_HASH, ZERO_HASH);
    }

    function test_acceptNextBatch_updatesState() public {
        Rollup.BlockCommitment[] memory batch = _buildLinkedBatch(MOCK_GENESIS_HASH);
        bytes32 expectedRoot = rollup.calculateBatchRoot(batch);

        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(batch, new Rollup.DepositsInBlock[](0), 0);

        assertEq(rollup.nextBatchIndex(), 2, "next batch index not incremented");
        assertEq(rollup.acceptedBatchHash(1), expectedRoot, "accepted root mismatch");
        assertEq(rollup.lastBlockHashInBatch(1), batch[1].blockHash, "last block hash mismatch");
    }

    function test_acceptNextBatch_revertsWhenBatchSizeIsInvalid() public {
        Rollup.BlockCommitment[] memory shortBatch = new Rollup.BlockCommitment[](1);
        shortBatch[0] = _buildCommitment(MOCK_GENESIS_HASH, keccak256("short-batch"), ZERO_HASH, ZERO_HASH);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchSize.selector, 2, 1));
        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(shortBatch, new Rollup.DepositsInBlock[](0), 0);
    }

    function test_acceptNextBatch_revertsWhenPreviousHashIsWrong() public {
        bytes32 wrongPrevHash = keccak256("wrong-prev-hash");
        Rollup.BlockCommitment[] memory batch = _buildLinkedBatch(wrongPrevHash);

        vm.expectRevert(
            abi.encodeWithSelector(IRollupErrors.WrongPreviousBlockHash.selector, MOCK_GENESIS_HASH, wrongPrevHash)
        );
        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(batch, new Rollup.DepositsInBlock[](0), 0);
    }

    function test_acceptNextBatch_revertsWhenBatchSequenceBreaks() public {
        Rollup.BlockCommitment[] memory batch = new Rollup.BlockCommitment[](2);
        bytes32 blockHash1 = keccak256("seq-1");
        bytes32 badPrev = keccak256("seq-bad-prev");

        batch[0] = _buildCommitment(MOCK_GENESIS_HASH, blockHash1, ZERO_HASH, ZERO_HASH);
        batch[1] = _buildCommitment(badPrev, keccak256("seq-2"), ZERO_HASH, ZERO_HASH);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBlockSequence.selector, 0, blockHash1, badPrev));
        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(batch, new Rollup.DepositsInBlock[](0), 0);
    }
}
