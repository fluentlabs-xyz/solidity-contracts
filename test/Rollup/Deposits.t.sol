// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {MockNitroVerifier} from "../mocks/MockNitroVerifier.sol";
import {MockDepositBridge} from "../mocks/MockDepositBridge.sol";
import {L2BlockHeader, BatchStatus} from "../../contracts/interfaces/IRollupTypes.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";

import {RollupAssertions} from "./Base.t.sol";

/**
 * @notice Covers Rollup._checkDeposits by feeding multiple L1 deposits into acceptNextBatch.
 */
contract DepositsTest is RollupAssertions {
    bytes32[3] internal _depositIds = [keccak256("deposit-0"), keccak256("deposit-1"), keccak256("deposit-2")];

    bytes32 internal _depositRoot;
    uint256 internal _depositCount = 3;

    MockDepositBridge internal depositsBridge;

    function setUp() public override {
        depositsBridge = new MockDepositBridge();
        for (uint256 i = 0; i < 3; i++) {
            depositsBridge.enqueue(_depositIds[i], block.number);
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

    function test_acceptNextBatch_checksDeposits_forMultipleDeposits() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);

        // Trigger _checkDeposits for exactly one header (batch header index 0).
        batch[0].depositRoot = _depositRoot;
        batch[0].depositCount = _depositCount;

        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 1);

        assertEq(uint8(rollup.getBatch(1).status), uint8(BatchStatus.HeadersSubmitted));
        assertEq(depositsBridge.poppedCount(), _depositCount, "not all deposits were popped");
    }

    function test_RevertIf_acceptNextBatch_depositRootMismatch() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        batch[0].depositRoot = keccak256("wrong-root");
        batch[0].depositCount = 3;

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.DepositRootMismatch.selector, batch[0].blockHash));
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 1);
    }

    function test_acceptNextBatch_zeroDepositsSkipsCheck() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 1);
        assertEq(uint8(rollup.getBatch(1).status), uint8(BatchStatus.HeadersSubmitted), "should accept without deposits");
        assertEq(depositsBridge.poppedCount(), 0, "no deposits should be popped");
    }

    function test_acceptNextBatch_checksDeposits_forMultipleDeposits_WithBlobs() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);

        // Trigger _checkDeposits for exactly one header (batch header index 0).
        batch[0].depositRoot = _depositRoot;
        batch[0].depositCount = _depositCount;

        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 1);

        uint256 batchIndex = 1;
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.HeadersSubmitted));
        assertEq(depositsBridge.poppedCount(), _depositCount, "not all deposits were popped");

        bytes32[] memory blobs = new bytes32[](1);
        blobs[0] = keccak256(abi.encode("blob", batchIndex, uint256(0)));
        vm.blobhashes(blobs);
        vm.prank(sequencer);
        rollup.submitBlobs(batchIndex, 1);

        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Accepted), "batch should become Accepted");

        bytes32[] memory storedBlobHashes = rollup.batchBlobHashes(batchIndex);
        assertEq(storedBlobHashes.length, 1, "stored blob hash count mismatch");
        assertEq(storedBlobHashes[0], blobs[0], "stored blob hash mismatch");
    }
}
