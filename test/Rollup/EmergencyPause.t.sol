// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RollupBase} from "./Base.t.sol";

contract EmergencyPauseTest is RollupBase {
    function test_emergencyPauseAndUnpause() public {
        vm.prank(admin);
        rollup.pause();
        assertTrue(rollup.paused());

        vm.prank(admin);
        rollup.unpause();
        assertFalse(rollup.paused());
    }

    function test_pausedBlocksAcceptNextBatch() public {
        vm.prank(admin);
        rollup.pause();

        vm.expectRevert();
        vm.prank(sequencer);
        rollup.acceptNextBatch(_makeBatch(GENESIS_HASH), 1);
    }
}

