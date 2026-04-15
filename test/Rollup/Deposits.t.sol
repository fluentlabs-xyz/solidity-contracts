// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {MockNitroVerifier} from "../mocks/MockNitroVerifier.sol";
import {MockDepositBridge} from "../mocks/MockDepositBridge.sol";
import {L2BlockHeader, BlockDeposit, BatchStatus} from "../../contracts/interfaces/rollup/IRollupTypes.sol";
import {IRollupErrors} from "../../contracts/interfaces/rollup/IRollup.sol";

import {RollupAssertions} from "./Base.t.sol";

/**
 * @notice Covers Rollup._checkDeposits by feeding multiple L1 deposits into commitBatch.
 */
contract DepositsTest is RollupAssertions {
    bytes32[3] internal _depositIds = [keccak256("deposit-0"), keccak256("deposit-1"), keccak256("deposit-2")];

    bytes32 internal _depositRoot;
    uint8 internal constant _depositCount = 3;

    MockDepositBridge internal depositsBridge;

    function setUp() public override {
        depositsBridge = new MockDepositBridge();
        for (uint256 i = 0; i < 3; i++) {
            depositsBridge.enqueue(_depositIds[i]);
        }
        bridgeAddr = address(depositsBridge);
        nitroVerifier = new MockNitroVerifier();
        rollup = _deployRollup(bridgeAddr);

        bytes32[] memory ids = new bytes32[](3);
        ids[0] = _depositIds[0];
        ids[1] = _depositIds[1];
        ids[2] = _depositIds[2];
        _depositRoot = keccak256(abi.encodePacked(ids));
    }

    function test_commitBatch_checksDeposits_forMultipleDeposits() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        bytes32 batchRoot = _computeBatchRoot(batch);

        BlockDeposit[] memory deposits = new BlockDeposit[](1);
        deposits[0] = BlockDeposit({depositRoot: _depositRoot, depositCount: _depositCount});

        vm.prank(sequencer);
        rollup.commitBatch(batchRoot, batch[batch.length - 1].blockHash, uint24(batch.length), deposits, 1);

        assertEq(uint8(rollup.getBatch(1).status), uint8(BatchStatus.Committed));
        assertEq(depositsBridge.poppedCount(), _depositCount, "not all deposits were popped");
    }

    function test_RevertIf_commitBatch_depositRootMismatch() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        bytes32 batchRoot = _computeBatchRoot(batch);

        BlockDeposit[] memory deposits = new BlockDeposit[](1);
        deposits[0] = BlockDeposit({depositRoot: keccak256("wrong-root"), depositCount: 3});

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.DepositRootMismatch.selector, _depositRoot, keccak256("wrong-root")));
        vm.prank(sequencer);
        rollup.commitBatch(batchRoot, batch[batch.length - 1].blockHash, uint24(batch.length), deposits, 1);
    }

    /// @dev Regression: commitBatch with multiple blockDeposits must advance the
    ///      bridge cursor between _checkDeposits calls. Without the fix, cursor is
    ///      passed by value (uint64) so block 2+ re-reads block 1's messages and
    ///      reverts with DepositRootMismatch.
    function test_commitBatch_multipleBlocksWithDeposits() public {
        // --- arrange: 5 deposits split across 2 blocks (3 + 2) ---
        bytes32[5] memory ids;
        for (uint256 i = 0; i < 5; i++) {
            ids[i] = keccak256(abi.encode("multi-deposit", i));
        }

        MockDepositBridge multiBridge = new MockDepositBridge();
        for (uint256 i = 0; i < 5; i++) {
            multiBridge.enqueue(ids[i]);
        }

        rollup = _deployRollup(address(multiBridge));

        // Block 1: deposits 0,1,2
        bytes32[] memory block1Ids = new bytes32[](3);
        block1Ids[0] = ids[0];
        block1Ids[1] = ids[1];
        block1Ids[2] = ids[2];
        bytes32 block1Root = keccak256(abi.encodePacked(block1Ids));

        // Block 2: deposits 3,4
        bytes32[] memory block2Ids = new bytes32[](2);
        block2Ids[0] = ids[3];
        block2Ids[1] = ids[4];
        bytes32 block2Root = keccak256(abi.encodePacked(block2Ids));

        L2BlockHeader[] memory batch = new L2BlockHeader[](2);
        bytes32 prev = GENESIS_HASH;

        bytes32 hash0 = keccak256(abi.encode("block", uint256(0), prev));
        batch[0] = L2BlockHeader({
            previousBlockHash: prev,
            blockHash: hash0,
            withdrawalRoot: EXAMPLE_WITHDRAWAL_ROOT,
            depositRoot: block1Root,
            depositCount: 3
        });
        prev = hash0;

        bytes32 hash1 = keccak256(abi.encode("block", uint256(1), prev));
        batch[1] = L2BlockHeader({
            previousBlockHash: prev,
            blockHash: hash1,
            withdrawalRoot: EXAMPLE_WITHDRAWAL_ROOT,
            depositRoot: block2Root,
            depositCount: 2
        });

        bytes32 batchRoot = _computeBatchRoot(batch);

        BlockDeposit[] memory deposits = new BlockDeposit[](2);
        deposits[0] = BlockDeposit({depositRoot: block1Root, depositCount: 3});
        deposits[1] = BlockDeposit({depositRoot: block2Root, depositCount: 2});

        // --- act ---
        vm.prank(sequencer);
        rollup.commitBatch(batchRoot, hash1, uint24(batch.length), deposits, 1);

        // --- assert ---
        assertEq(uint8(rollup.getBatch(1).status), uint8(BatchStatus.Committed), "batch should be committed");
        assertEq(multiBridge.poppedCount(), 5, "all 5 deposits should be consumed");
    }

    function test_commitBatch_checksDeposits_forMultipleDeposits_WithBlobs() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        bytes32 batchRoot = _computeBatchRoot(batch);

        BlockDeposit[] memory deposits = new BlockDeposit[](1);
        deposits[0] = BlockDeposit({depositRoot: _depositRoot, depositCount: _depositCount});

        vm.prank(sequencer);
        rollup.commitBatch(batchRoot, batch[batch.length - 1].blockHash, uint24(batch.length), deposits, 1);

        uint256 batchIndex = 1;
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Committed));
        assertEq(depositsBridge.poppedCount(), _depositCount, "not all deposits were popped");

        bytes32[] memory blobs = new bytes32[](1);
        blobs[0] = keccak256(abi.encode("blob", batchIndex, uint256(0)));
        vm.blobhashes(blobs);
        vm.prank(sequencer);
        rollup.submitBlobs(batchIndex, 1);

        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Submitted), "batch should become Submitted");

        bytes32[] memory storedBlobHashes = rollup.batchBlobHashes(batchIndex);
        assertEq(storedBlobHashes.length, 1, "stored blob hash count mismatch");
        assertEq(storedBlobHashes[0], blobs[0], "stored blob hash mismatch");
    }
}
