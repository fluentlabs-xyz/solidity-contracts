// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {MockNitroVerifier} from "../mocks/MockNitroVerifier.sol";
import {MockDepositBridge} from "../mocks/MockDepositBridge.sol";
import {L2BlockHeader, BlockDeposit, BatchStatus} from "../../contracts/interfaces/IRollupTypes.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";

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
        rollup.commitBatch(batchRoot, uint24(batch.length), deposits, 1);

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
        rollup.commitBatch(batchRoot, uint24(batch.length), deposits, 1);
    }

    function test_commitBatch_zeroDepositsSkipsCheck() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        bytes32 batchRoot = _computeBatchRoot(batch);
        BlockDeposit[] memory emptyDeposits = new BlockDeposit[](0);

        vm.prank(sequencer);
        rollup.commitBatch(batchRoot, uint24(batch.length), emptyDeposits, 0);
        assertEq(uint8(rollup.getBatch(1).status), uint8(BatchStatus.Committed), "should accept without deposits");
        assertEq(depositsBridge.poppedCount(), 0, "no deposits should be popped");
    }

    function test_commitBatch_checksDeposits_forMultipleDeposits_WithBlobs() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        bytes32 batchRoot = _computeBatchRoot(batch);

        BlockDeposit[] memory deposits = new BlockDeposit[](1);
        deposits[0] = BlockDeposit({depositRoot: _depositRoot, depositCount: _depositCount});

        vm.prank(sequencer);
        rollup.commitBatch(batchRoot, uint24(batch.length), deposits, 1);

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
