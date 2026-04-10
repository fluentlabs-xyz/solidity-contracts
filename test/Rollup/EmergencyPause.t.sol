// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {RollupAssertions} from "./Base.t.sol";
import {BlockDeposit} from "../../contracts/interfaces/IRollupTypes.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract EmergencyPauseTest is RollupAssertions {
    function test_emergencyPauseAndUnpause() public {
        vm.prank(admin);
        rollup.pause();
        assertTrue(rollup.paused());

        vm.prank(admin);
        rollup.unpause();
        assertFalse(rollup.paused());
    }

    function test_pausedBlockscommitBatch() public {
        vm.prank(admin);
        rollup.pause();

        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vm.prank(sequencer);
        rollup.commitBatch(keccak256("root"), 1, new BlockDeposit[](0), 1);
    }

    function test_RevertIf_pause_callerNotEmergencyRole() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, rollup.EMERGENCY_ROLE()));
        vm.prank(user);
        rollup.pause();
    }

    function test_RevertIf_unpause_callerNotEmergencyRole() public {
        vm.prank(admin);
        rollup.pause();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, rollup.EMERGENCY_ROLE()));
        vm.prank(user);
        rollup.unpause();
    }

    function test_pausedBlocksSubmitBlobs() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        vm.prank(admin);
        rollup.pause();
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        _submitBlobs(batchIndex, 0);
    }

    function test_pausedBlocksPreconfirmBatch() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batchIndex, 0);
        vm.prank(admin);
        rollup.pause();
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        _preconfirmBatch(batchIndex);
    }

    function test_pausedBlocksFinalizeBatches() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);
        vm.roll(block.number + FINALIZATION_DELAY + 1);
        vm.prank(admin);
        rollup.pause();
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        rollup.finalizeBatches(batchIndex);
    }
}
