// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {RollupBase, Vm} from "./Base.t.sol";

contract MockBlobHashGetter {
    bytes32 internal blobHash;

    function setBlobHash(bytes32 value) external {
        blobHash = value;
    }

    fallback() external {
        bytes32 value = blobHash;
        assembly {
            mstore(0x00, value)
            return(0x00, 0x20)
        }
    }
}

contract RollupDaConfigTest is RollupBase {
    bytes32 internal constant DA_CHECK_UPDATED_SIG = keccak256("DaCheckUpdated(bool,bool)");

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

    function test_setDaCheck_updatesStateAndEmitsEvent() public {
        vm.recordLogs();
        rollup.setDaCheck(true);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(rollup) && entries[i].topics.length > 0 && entries[i].topics[0] == DA_CHECK_UPDATED_SIG) {
                (bool oldValue, bool newValue) = abi.decode(entries[i].data, (bool, bool));
                assertEq(oldValue, false, "old value mismatch");
                assertEq(newValue, true, "new value mismatch");
                found = true;
                break;
            }
        }
        assertTrue(found, "DaCheckUpdated event was not emitted");
    }

    function test_setDaCheck_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), ATTACKER));
        vm.prank(ATTACKER);
        rollup.setDaCheck(true);
    }

    function test_calculateBlobHash_isDeterministicAndMasked() public {
        bytes memory blob = hex"abcdef123456";
        bytes32 hash1 = rollup.calculateBlobHash(blob);
        bytes32 hash2 = rollup.calculateBlobHash(blob);
        bytes32 rawSha = sha256(blob);
        uint256 lowMask = type(uint248).max;

        assertEq(hash1, hash2, "blob hash must be deterministic");
        assertEq(uint256(hash1) >> 248, 1, "first byte must be 0x01");
        assertEq(uint256(hash1) & lowMask, uint256(rawSha) & lowMask, "low 31 bytes must match sha256 output");
    }

    function test_calculateBlobHash_handlesEmptyBlob() public {
        bytes32 hash = rollup.calculateBlobHash("");
        assertEq(uint256(hash) >> 248, 1, "first byte must be 0x01 for empty blob");
    }

    function test_acceptNextBatch_daCheckPassesWhenBlobHashMatches() public {
        Rollup.BlockCommitment[] memory batch = new Rollup.BlockCommitment[](2);
        bytes32 blockHash1 = keccak256("da-batch-1");
        bytes32 blockHash2 = keccak256("da-batch-2");
        batch[0] = _buildCommitment(MOCK_GENESIS_HASH, blockHash1, ZERO_HASH, ZERO_HASH);
        batch[1] = _buildCommitment(blockHash1, blockHash2, ZERO_HASH, ZERO_HASH);

        MockBlobHashGetter getter = new MockBlobHashGetter();
        rollup.setBlobHashGetter(address(getter));
        rollup.setDaCheck(true);

        bytes32 batchRoot = rollup.calculateBatchRoot(batch);
        bytes32 expectedBlobHash = rollup.calculateBlobHash(abi.encodePacked(batchRoot));
        getter.setBlobHash(expectedBlobHash);

        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(1, batch, new Rollup.DepositsInBlock[](0));

        assertEq(rollup.nextBatchIndex(), 2, "batch should be accepted with matching DA hash");
    }

    function test_acceptNextBatch_daCheckRevertsWhenBlobHashMismatches() public {
        Rollup.BlockCommitment[] memory batch = new Rollup.BlockCommitment[](2);
        bytes32 blockHash1 = keccak256("da-batch-bad-1");
        bytes32 blockHash2 = keccak256("da-batch-bad-2");
        batch[0] = _buildCommitment(MOCK_GENESIS_HASH, blockHash1, ZERO_HASH, ZERO_HASH);
        batch[1] = _buildCommitment(blockHash1, blockHash2, ZERO_HASH, ZERO_HASH);

        MockBlobHashGetter getter = new MockBlobHashGetter();
        rollup.setBlobHashGetter(address(getter));
        rollup.setDaCheck(true);

        bytes32 batchRoot = rollup.calculateBatchRoot(batch);
        bytes32 expectedBlobHash = rollup.calculateBlobHash(abi.encodePacked(batchRoot));
        bytes32 wrongBlobHash = bytes32(uint256(1));
        getter.setBlobHash(wrongBlobHash);

        vm.expectRevert(abi.encodeWithSelector(Rollup.DaBlobHashMismatch.selector, expectedBlobHash, wrongBlobHash));
        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(1, batch, new Rollup.DepositsInBlock[](0));
    }
}
