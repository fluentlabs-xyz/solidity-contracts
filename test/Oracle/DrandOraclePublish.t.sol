// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IDrandOracle} from "../../contracts/interfaces/oracles/IDrandOracle.sol";
import {DrandOracle} from "../../contracts/oracles/DrandOracle.sol";
import {DrandQuicknetVectors} from "../bls/DrandQuicknetVectors.sol";

contract DrandOraclePublishTest is Test {
    /// drand quicknet round 8191 is live at this timestamp, so the retention
    /// window still reaches back to round 1.
    uint256 internal constant NOW = 1_692_827_937;

    DrandOracle internal oracle;
    address internal anyone = makeAddr("anyone");

    function setUp() public {
        vm.warp(NOW);
        oracle = new DrandOracle(address(this));
    }

    /// R2: any address publishes; there is no role and no allowlist.
    function test_publish_isPermissionless() public {
        DrandQuicknetVectors.Vector memory v = DrandQuicknetVectors.round1();

        vm.prank(anyone);
        oracle.publish(v.round, v.uncompressed);

        assertEq(oracle.randomnessOf(v.round), v.randomness, "stored value must be drand's randomness");
    }

    /// R7: once published, the value of a round does not change.
    function test_publish_valueIsFinalAfterFirstPublication() public {
        DrandQuicknetVectors.Vector memory v = DrandQuicknetVectors.round1();

        vm.prank(anyone);
        oracle.publish(v.round, v.uncompressed);

        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundAlreadyPublished.selector, v.round));
        vm.prank(makeAddr("someoneElse"));
        oracle.publish(v.round, v.uncompressed);

        assertEq(oracle.randomnessOf(v.round), v.randomness, "value must be unchanged");
    }

    /// R15: a round outside the retention window is rejected even when the
    /// signature presented for it is a genuine drand beacon.
    function test_RevertIf_publish_roundOutsideRetentionWindow() public {
        DrandQuicknetVectors.Vector memory old = DrandQuicknetVectors.round1();
        DrandQuicknetVectors.Vector memory ahead = DrandQuicknetVectors.round10M();

        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundInFuture.selector, ahead.round, oracle.currentRound()));
        vm.prank(anyone);
        oracle.publish(ahead.round, ahead.uncompressed);

        vm.warp(DrandQuicknetVectors.round31799517().publishTime);
        vm.expectRevert(
            abi.encodeWithSelector(IDrandOracle.RoundTooOld.selector, old.round, oracle.oldestRetainedRound())
        );
        vm.prank(anyone);
        oracle.publish(old.round, old.uncompressed);
    }
}
