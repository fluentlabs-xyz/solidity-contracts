// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {VerifierMock} from "../../contracts/mocks/VerifierMock.sol";
import {RollupBase} from "./Base.t.sol";

contract RollupAccessControlTest is RollupBase {
    bytes4 internal constant OWNABLE_UNAUTHORIZED_SELECTOR = bytes4(keccak256("OwnableUnauthorizedAccount(address)"));

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
        bytes32 blockHash1 = keccak256("acl-1");
        bytes32 blockHash2 = keccak256("acl-2");

        batch[0] = _buildCommitment(prevHash, blockHash1, ZERO_HASH, ZERO_HASH);
        batch[1] = _buildCommitment(blockHash1, blockHash2, ZERO_HASH, ZERO_HASH);
    }

    function test_owner_canCallPrivilegedFunctions() public {
        rollup.setBridge(address(0x9999));
        assertEq(rollup.bridge(), address(0x9999), "bridge update failed");

        VerifierMock newVerifier = new VerifierMock();
        rollup.updateVerifier(address(newVerifier));

        rollup.setDaCheck(true);

        rollup.pause();
        assertEq(rollup.paused(), true, "pause failed");

        rollup.unpause();
        assertEq(rollup.paused(), false, "unpause failed");
    }

    function test_nonOwner_revertsOnPrivilegedFunctions() public {
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTHORIZED_SELECTOR, ATTACKER));
        vm.prank(ATTACKER);
        rollup.setBridge(address(0x9999));

        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTHORIZED_SELECTOR, ATTACKER));
        vm.prank(ATTACKER);
        rollup.updateVerifier(address(0x8888));

        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTHORIZED_SELECTOR, ATTACKER));
        vm.prank(ATTACKER);
        rollup.setDaCheck(true);

        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTHORIZED_SELECTOR, ATTACKER));
        vm.prank(ATTACKER);
        rollup.pause();

        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTHORIZED_SELECTOR, ATTACKER));
        vm.prank(ATTACKER);
        rollup.unpause();

        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTHORIZED_SELECTOR, ATTACKER));
        vm.prank(ATTACKER);
        rollup.forceRevertBatch(1);
    }

    function test_nonSequencer_revertsOnAcceptNextBatch() public {
        Rollup.BlockCommitment[] memory batch = _buildValidBatch(MOCK_GENESIS_HASH);

        vm.expectRevert(bytes4(keccak256("OnlySequencer()")));
        vm.prank(ATTACKER);
        rollup.acceptNextBatch(1, batch, new Rollup.DepositsInBlock[](0), 0);
    }
}
