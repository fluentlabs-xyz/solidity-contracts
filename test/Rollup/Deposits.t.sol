// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockNitroVerifier} from "../mocks/MockNitroVerifier.sol";
import {MockDepositBridge} from "../mocks/MockDepositBridge.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {InitConfiguration, L2BlockHeader, BatchStatus} from "../../contracts/interfaces/IRollupTypes.sol";
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
        depositsBridge = new MockDepositBridge(1000);
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
        rollup.acceptNextBatch(batch, 0);
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

    // ============ maxDepositsPerBatch cap ============

    function test_acceptNextBatch_singleHeaderAtLimit_succeeds() public {
        Rollup r = _deployRollupWithDepositCap(3);

        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        batch[0].depositRoot = _depositRoot;
        batch[0].depositCount = 3;

        vm.prank(sequencer);
        r.acceptNextBatch(batch, 1);

        assertEq(uint8(r.getBatch(1).status), uint8(BatchStatus.HeadersSubmitted));
    }

    function test_RevertIf_acceptNextBatch_singleHeaderExceedsCap() public {
        Rollup r = _deployRollupWithDepositCap(2);

        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        batch[0].depositRoot = _depositRoot;
        batch[0].depositCount = 3;

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.DepositCountTooLarge.selector, 3));
        vm.prank(sequencer);
        r.acceptNextBatch(batch, 1);
    }

    /// @dev Proves the cap is a per-batch total, not a per-header check. With distribution
    ///      [1,1,1,0] and cap=3, the sum reaches exactly 3 at header index 2 and acceptance
    ///      succeeds — whereas a per-header regression would have passed trivially.
    function test_acceptNextBatch_depositsSplitAcrossHeaders_atLimit_succeeds() public {
        Rollup r = _deployRollupWithDepositCap(3);

        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        batch[0].depositRoot = keccak256(abi.encodePacked(_depositIds[0]));
        batch[0].depositCount = 1;
        batch[1].depositRoot = keccak256(abi.encodePacked(_depositIds[1]));
        batch[1].depositCount = 1;
        batch[2].depositRoot = keccak256(abi.encodePacked(_depositIds[2]));
        batch[2].depositCount = 1;

        vm.prank(sequencer);
        r.acceptNextBatch(batch, 1);

        assertEq(uint8(r.getBatch(1).status), uint8(BatchStatus.HeadersSubmitted));
        assertEq(depositsBridge.poppedCount(), 3, "all three deposits should be popped");
    }

    /// @dev Proves the cap is a per-batch total, not a per-header check. Distribution
    ///      [1,1,1,0] would pass a per-header check with cap=2 but must fail the batch total.
    function test_RevertIf_acceptNextBatch_depositsSplitAcrossHeaders_exceedsCap() public {
        Rollup r = _deployRollupWithDepositCap(2);

        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);
        batch[0].depositRoot = keccak256(abi.encodePacked(_depositIds[0]));
        batch[0].depositCount = 1;
        batch[1].depositRoot = keccak256(abi.encodePacked(_depositIds[1]));
        batch[1].depositCount = 1;
        batch[2].depositRoot = keccak256(abi.encodePacked(_depositIds[2]));
        batch[2].depositCount = 1;

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.DepositCountTooLarge.selector, 3));
        vm.prank(sequencer);
        r.acceptNextBatch(batch, 1);
    }

    // ============ Helpers ============

    function _deployRollupWithDepositCap(uint64 cap) internal returns (Rollup) {
        InitConfiguration memory cfg = _defaultInitConfig(bridgeAddr);
        cfg.maxDepositsPerBatch = cap;
        Rollup impl = new Rollup();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Rollup.initialize, (abi.encode(cfg))));
        Rollup r = Rollup(address(proxy));
        vm.prank(admin);
        r.enableNitroVerifier(address(nitroVerifier));
        return r;
    }
}
