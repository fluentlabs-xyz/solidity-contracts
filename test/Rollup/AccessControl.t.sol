// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {RollupStorageLayout} from "../../contracts/rollup/RollupStorage.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {VerifierMock} from "../../contracts/mocks/VerifierMock.sol";
import {RollupBase} from "./Base.t.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract RollupAccessControlTest is RollupBase {

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

    function _buildValidBatch(bytes32 prevHash) internal pure returns (RollupStorageLayout.BlockCommitment[] memory batch) {
        batch = new RollupStorageLayout.BlockCommitment[](2);
        bytes32 blockHash1 = keccak256("acl-1");
        bytes32 blockHash2 = keccak256("acl-2");

        batch[0] = _buildCommitment(prevHash, blockHash1, ZERO_HASH, ZERO_HASH);
        batch[1] = _buildCommitment(blockHash1, blockHash2, ZERO_HASH, ZERO_HASH);
    }

    function test_owner_canCallPrivilegedFunctions() public {
        rollup.setBridge(address(0x9999));
        assertEq(rollup.bridge(), address(0x9999), "bridge update failed");

        VerifierMock newVerifier = new VerifierMock();
        rollup.setVerifier(address(newVerifier));

        rollup.setDaCheck(true);

        rollup.pause();
        assertEq(rollup.paused(), true, "pause failed");

        rollup.unpause();
        assertEq(rollup.paused(), false, "unpause failed");
    }

    function test_nonAdmin_revertsOnPrivilegedFunctions() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ATTACKER, bytes32(0)));
        vm.prank(ATTACKER);
        rollup.setBridge(address(0x9999));

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ATTACKER, bytes32(0)));
        vm.prank(ATTACKER);
        rollup.setVerifier(address(0x8888));

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ATTACKER, bytes32(0)));
        vm.prank(ATTACKER);
        rollup.setDaCheck(true);

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ATTACKER, keccak256("PAUSER_ROLE")));
        vm.prank(ATTACKER);
        rollup.pause();

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ATTACKER, keccak256("PAUSER_ROLE")));
        vm.prank(ATTACKER);
        rollup.unpause();

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ATTACKER, bytes32(0)));
        vm.prank(ATTACKER);
        rollup.forceRevertBatch(1);
    }

    function test_nonSequencer_revertsOnAcceptNextBatch() public {
        RollupStorageLayout.BlockCommitment[] memory batch = _buildValidBatch(MOCK_GENESIS_HASH);

        vm.expectRevert(IRollupErrors.OnlySequencer.selector);
        vm.prank(ATTACKER);
        rollup.acceptNextBatch(batch, new RollupStorageLayout.DepositsInBlock[](0), 0);
    }
}
