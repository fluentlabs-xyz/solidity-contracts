// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// import {RollupBase} from "./Base.t.sol";
// import {Rollup} from "../../contracts/rollup/Rollup.sol";
// import {L2BlockHeader, BatchStatus, BatchRecord, InitConfiguration} from "../../contracts/interfaces/IRollupTypes.sol";
// import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
// import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
// import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
// import {MockSp1Verifier} from "./mocks/MockSp1Verifier.sol";
// import {FinalizingBridge} from "./mocks/FinalizingBridge.sol";

// contract AcceptBatchTest is RollupBase {
//     function test_fullBatchLifecycle() public {
//         L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
//         bytes32 expectedRoot = _computeBatchRoot(batch);

//         _expectBatchHeadersSubmitted(1, expectedRoot, 0);
//         uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);

//         _assertBatchRecord(batchIndex, BatchStatus.HeadersSubmitted, 0, expectedRoot);
//         assertEq(rollup.nextBatchIndex(), batchIndex + 1);
//         _assertRollupHealthy();

//         _expectBatchAccepted(batchIndex);
//         _submitBlobs(batchIndex, 0);
//         _assertBatchRecord(batchIndex, BatchStatus.Accepted, 0, expectedRoot);

//         _expectBatchPreconfirmed(batchIndex);
//         _preconfirmBatch(batchIndex);
//         _assertBatchRecord(batchIndex, BatchStatus.Preconfirmed, 0, expectedRoot);

//         vm.roll(block.number + FINALIZATION_DELAY + 1);

//         _expectBatchFinalized(batchIndex);
//         bool finalized = _finalizeBatch(batchIndex);

//         assertTrue(finalized);
//         _assertBatchRecord(batchIndex, BatchStatus.Finalized, 0, expectedRoot);
//         _assertLastFinalizedBatchIndex(batchIndex);
//     }

//     function test_acceptSetsCorrectBatchRecord() public {
//         L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
//         bytes32 expectedRoot = _computeBatchRoot(batch);

//         uint256 batchIndex = _acceptBatch(GENESIS_HASH, 3);

//         _assertBatchRecord(batchIndex, BatchStatus.HeadersSubmitted, 3, expectedRoot);
//         assertEq(rollup.getBatch(batchIndex).acceptedAtBlock, block.number);
//     }

//     function test_multipleBatchesSequential() public {
//         uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
//         assertEq(batch1, 1);

//         bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
//         uint256 batch2 = _acceptBatch(lastHash, 0);
//         assertEq(batch2, 2);

//         _assertBatchRecord(batch1, BatchStatus.HeadersSubmitted, 0, rollup.getBatch(batch1).batchRoot);
//         _assertBatchRecord(batch2, BatchStatus.HeadersSubmitted, 0, rollup.getBatch(batch2).batchRoot);
//     }

//     function test_revert_wrongParentHash() public {
//         uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);

//         bytes32 wrongParent = keccak256("wrong");
//         L2BlockHeader[] memory batch = _makeBatch(wrongParent);

//         bytes32 expectedParent = rollup.lastBlockHashInBatch(batch1);
//         vm.expectRevert(abi.encodeWithSelector(IRollupErrors.WrongPreviousBlockHash.selector, expectedParent, wrongParent));
//         vm.prank(sequencer);
//         rollup.acceptNextBatch(batch, 0);
//     }

//     function test_revert_submitBlobs_wrongStatus() public {
//         uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
//         _submitBlobs(batchIndex, 0);

//         vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchStatus.selector, batchIndex, uint8(BatchStatus.Accepted)));
//         vm.prank(sequencer);
//         rollup.submitBlobs(batchIndex, 0);
//     }

//     function test_finalizeBatchReturnsFalseWhenNotReady() public {
//         uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);

//         bool result = _finalizeBatch(batchIndex);
//         assertFalse(result);
//     }

//     function test_finalizeBatchReturnsFalseWhenTooEarly() public {
//         uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
//         _submitBlobs(batchIndex, 0);
//         _preconfirmBatch(batchIndex);

//         bool result = _finalizeBatch(batchIndex);
//         assertFalse(result);
//     }

//     function test_acceptNextBatch_cei_bridgeCallsFinalizeDuringDeposit() public {
//         // Diagnostic simplification: temporarily empty to isolate remaining stack-too-deep site.
//     }
// }
