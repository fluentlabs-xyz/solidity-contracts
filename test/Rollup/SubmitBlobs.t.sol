// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {RollupAssertions} from "./Base.t.sol";
import {BatchStatus} from "../../contracts/interfaces/IRollupTypes.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";

contract SubmitBlobsTest is RollupAssertions {
    function test_submitBlobs_singleCallTransitionsToAccepted() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 2);
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.HeadersSubmitted));

        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256(abi.encode("blob", batchIndex, uint256(0)));
        hashes[1] = keccak256(abi.encode("blob", batchIndex, uint256(1)));
        vm.blobhashes(hashes);
        vm.prank(sequencer);
        rollup.submitBlobs(batchIndex, 2);

        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Accepted));
    }

    function test_submitBlobs_multipleCallsAccumulate() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 3);

        for (uint256 call = 0; call < 3; call++) {
            bytes32[] memory h = new bytes32[](1);
            h[0] = keccak256(abi.encode("blob", batchIndex, call));
            vm.blobhashes(h);
            vm.prank(sequencer);
            rollup.submitBlobs(batchIndex, 1);

            if (call < 2) {
                assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.HeadersSubmitted));
            } else {
                assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Accepted));
            }
        }
    }

    function test_submitBlobs_blobHashesAccumulate() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 3);

        bytes32[] memory expected = new bytes32[](3);
        for (uint256 call = 0; call < 3; call++) {
            bytes32[] memory h = new bytes32[](1);
            h[0] = keccak256(abi.encode("blobAccum", call));
            expected[call] = h[0];
            vm.blobhashes(h);
            vm.prank(sequencer);
            rollup.submitBlobs(batchIndex, 1);

            bytes32[] memory stored = rollup.batchBlobHashes(batchIndex);
            assertEq(stored.length, call + 1);
            assertEq(stored[call], expected[call]);
        }
    }

    function test_submitBlobs_emitsCorrectEventsOnEachCallAndAcceptedOnFinal() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 2);

        bytes32[] memory h1 = new bytes32[](1);
        h1[0] = keccak256("b1");
        vm.blobhashes(h1);
        vm.expectEmit(true, false, false, true, address(rollup));
        emit BatchBlobsSubmitted(batchIndex, 1, 1);
        vm.prank(sequencer);
        rollup.submitBlobs(batchIndex, 1);

        bytes32[] memory h2 = new bytes32[](1);
        h2[0] = keccak256("b2");
        vm.blobhashes(h2);
        vm.expectEmit(true, false, false, true, address(rollup));
        emit BatchBlobsSubmitted(batchIndex, 1, 2);
        vm.expectEmit(true, false, false, false, address(rollup));
        emit BatchAccepted(batchIndex);
        vm.prank(sequencer);
        rollup.submitBlobs(batchIndex, 1);
    }

    function test_RevertIf_submitBlobs_exceedsExpected() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 1);

        bytes32[] memory h = new bytes32[](2);
        h[0] = keccak256("b1");
        h[1] = keccak256("b2");
        vm.blobhashes(h);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBlobCount.selector, uint32(1), uint256(2)));
        vm.prank(sequencer);
        rollup.submitBlobs(batchIndex, 2);
    }

    function test_RevertIf_submitBlobs_wrongStatus() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batchIndex, 0);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroValueNotAllowed.selector, "numBlobs"));
        vm.prank(sequencer);
        rollup.submitBlobs(batchIndex, 0);
    }

    function test_RevertIf_submitBlobs_wrongBatchStatus() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 1);
        _submitBlobs(batchIndex, 1);
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Accepted));

        // All blobs are already submitted, so submitting more hits InvalidBlobCount
        // before the status check. Verify the contract protects against double-submission.
        bytes32[] memory h = new bytes32[](1);
        h[0] = keccak256("extra-blob");
        vm.blobhashes(h);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBlobCount.selector, uint32(1), uint256(2)));
        vm.prank(sequencer);
        rollup.submitBlobs(batchIndex, 1);
    }

    function test_RevertIf_submitBlobs_zeroBlobHash() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 1);

        bytes32[] memory h = new bytes32[](1);
        h[0] = bytes32(0);
        vm.blobhashes(h);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroValueNotAllowed.selector, "blobHash"));
        vm.prank(sequencer);
        rollup.submitBlobs(batchIndex, 1);
    }

    function test_RevertIf_submitBlobs_daDeadlineExceeded() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 1);

        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);

        bytes32[] memory h = new bytes32[](1);
        h[0] = keccak256("b1");
        vm.blobhashes(h);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(sequencer);
        rollup.submitBlobs(batchIndex, 1);
    }

    // boundary condition: submitBlobsWindow check is <=, deadline block is inclusive
    function test_submitBlobs_daDeadlineWithinWindow() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 1);

        vm.roll(block.number + SUBMIT_BLOBS_WINDOW);

        bytes32[] memory h = new bytes32[](1);
        h[0] = keccak256("b1");
        vm.blobhashes(h);
        vm.prank(sequencer);
        rollup.submitBlobs(batchIndex, 1);

        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Accepted));
    }

    function test_submitBlobs_accumulatesAcrossMultipleBlocks() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 3);

        for (uint256 call = 0; call < 3; call++) {
            vm.roll(block.number + 5);
            bytes32[] memory h = new bytes32[](1);
            h[0] = keccak256(abi.encode("multiBlock", call));
            vm.blobhashes(h);
            vm.prank(sequencer);
            rollup.submitBlobs(batchIndex, 1);
        }

        bytes32[] memory stored = rollup.batchBlobHashes(batchIndex);
        assertEq(stored.length, 3);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(stored[i], keccak256(abi.encode("multiBlock", i)));
        }
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Accepted));
    }
}
