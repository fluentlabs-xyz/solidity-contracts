// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {RollupBase} from "./Base.t.sol";

contract RollupPauseTest is RollupBase {
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

    function _buildValidBatch(bytes32 prevHash) internal pure returns (Rollup.BlockCommitment[] memory batch) {
        batch = new Rollup.BlockCommitment[](2);
        bytes32 blockHash1 = keccak256("pause-batch-1");
        bytes32 blockHash2 = keccak256("pause-batch-2");

        batch[0] = _buildCommitment(prevHash, blockHash1, ZERO_HASH, ZERO_HASH);
        batch[1] = _buildCommitment(blockHash1, blockHash2, ZERO_HASH, ZERO_HASH);
    }

    function test_pauseUnpause_changesState() public {
        assertEq(rollup.paused(), false, "rollup must start unpaused");

        rollup.pause();
        assertEq(rollup.paused(), true, "pause not applied");

        rollup.unpause();
        assertEq(rollup.paused(), false, "unpause not applied");
    }

    function test_acceptNextBatch_revertsWhenPaused() public {
        Rollup.BlockCommitment[] memory batch = _buildValidBatch(MOCK_GENESIS_HASH);

        rollup.pause();

        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(1, batch, new Rollup.DepositsInBlock[](0));
    }

    function test_acceptNextBatch_worksAfterUnpause() public {
        Rollup.BlockCommitment[] memory batch = _buildValidBatch(MOCK_GENESIS_HASH);

        rollup.pause();
        rollup.unpause();

        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(1, batch, new Rollup.DepositsInBlock[](0));

        assertEq(rollup.nextBatchIndex(), 2, "batch not accepted after unpause");
    }
}
