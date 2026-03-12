// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RollupBase, MockNitroVerifier} from "./Base.t.sol";
import {RollupStorageLayout} from "../../contracts/rollup/RollupStorageLayout.sol";
import {INitroEnclaveVerifier} from "../../contracts/interfaces/INitroEnclaveVerifier.sol";

contract HappyPathTest is RollupBase {
    MockNitroVerifier internal nitroVerifier;

    bytes32 internal constant DUMMY_SIGNATURE = keccak256("signature");

    function setUp() public override {
        super.setUp();

        nitroVerifier = new MockNitroVerifier();

        vm.prank(admin);
        rollup.setNitroVerifier(address(nitroVerifier));
    }

    function test_fullBatchLifecycle() public {
        // ── 1. Accept ──────────────────────────────────────────────────────────
        uint256 batchIndex = _acceptBatch(GENESIS_HASH);

        assertEq(uint8(rollup.batchStatus(batchIndex)), uint8(RollupStorageLayout.BatchStatus.Accepted));
        assertEq(rollup.nextBatchIndex(), batchIndex + 1);

        // ── 2. PreConfirm ──────────────────────────────────────────────────────
        vm.prank(preconfirmer);
        rollup.commitPreConfirmation(address(nitroVerifier), batchIndex, DUMMY_SIGNATURE);

        assertEq(uint8(rollup.batchStatus(batchIndex)), uint8(RollupStorageLayout.BatchStatus.PreConfirmed));

        // ── 3. Finalize ────────────────────────────────────────────────────────
        vm.roll(block.number + APPROVE_BLOCK_COUNT + 1);

        bool finalized = rollup.ensureBatchFinalized(batchIndex);

        assertTrue(finalized);
        assertEq(uint8(rollup.batchStatus(batchIndex)), uint8(RollupStorageLayout.BatchStatus.Finalized));
    }
}
