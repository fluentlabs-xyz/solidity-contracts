// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {RollupBase, Vm} from "./Base.t.sol";

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
            if (
                entries[i].emitter == address(rollup) && entries[i].topics.length > 0
                    && entries[i].topics[0] == DA_CHECK_UPDATED_SIG
            ) {
                (bool oldValue, bool newValue) = abi.decode(entries[i].data, (bool, bool));
                assertEq(oldValue, false, "old value mismatch");
                assertEq(newValue, true, "new value mismatch");
                found = true;
                break;
            }
        }
        assertTrue(found, "DaCheckUpdated event was not emitted");
    }

    function test_setDaCheck_revertsForNonAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ATTACKER, bytes32(0)));
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

    function test_acceptNextBatch_daCheckRevertsWhenNumBlobsIsZero() public {
        Rollup.BlockCommitment[] memory batch = new Rollup.BlockCommitment[](2);
        bytes32 blockHash1 = keccak256("da-batch-1");
        bytes32 blockHash2 = keccak256("da-batch-2");
        batch[0] = _buildCommitment(MOCK_GENESIS_HASH, blockHash1, ZERO_HASH, ZERO_HASH);
        batch[1] = _buildCommitment(blockHash1, blockHash2, ZERO_HASH, ZERO_HASH);
        rollup.setDaCheck(true);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroValueNotAllowed.selector, "numBlobs"));
        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(batch, new Rollup.DepositsInBlock[](0), 0);
    }

    function test_acceptNextBatch_daCheckRevertsWhenBlobHashIsMissing() public {
        Rollup.BlockCommitment[] memory batch = new Rollup.BlockCommitment[](2);
        bytes32 blockHash1 = keccak256("da-batch-bad-1");
        bytes32 blockHash2 = keccak256("da-batch-bad-2");
        batch[0] = _buildCommitment(MOCK_GENESIS_HASH, blockHash1, ZERO_HASH, ZERO_HASH);
        batch[1] = _buildCommitment(blockHash1, blockHash2, ZERO_HASH, ZERO_HASH);

        rollup.setDaCheck(true);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroValueNotAllowed.selector, "blobHash"));
        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(batch, new Rollup.DepositsInBlock[](0), 1);
    }
}
