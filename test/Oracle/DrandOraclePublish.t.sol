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

    /// R15: a round above the window is rejected even when the signature
    /// presented for it is a genuine drand beacon.
    function test_RevertIf_publish_roundAboveWindow() public {
        DrandQuicknetVectors.Vector memory ahead = DrandQuicknetVectors.round10M();

        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundInFuture.selector, ahead.round, oracle.currentRound()));
        vm.prank(anyone);
        oracle.publish(ahead.round, ahead.uncompressed);
    }

    /// R15: a round below the window is rejected even when the signature
    /// presented for it is a genuine drand beacon.
    function test_RevertIf_publish_roundBelowWindow() public {
        DrandQuicknetVectors.Vector memory old = DrandQuicknetVectors.round1();
        vm.warp(DrandQuicknetVectors.round31799517().publishTime);

        vm.expectRevert(
            abi.encodeWithSelector(IDrandOracle.RoundTooOld.selector, old.round, oracle.oldestRetainedRound())
        );
        vm.prank(anyone);
        oracle.publish(old.round, old.uncompressed);
    }

    /// R15, upper bound, first invalid round: `currentRound() + 1` is refused.
    /// The window check precedes verification, so the signature never matters.
    function test_RevertIf_publish_roundIsCurrentPlusOne() public {
        uint64 current = oracle.currentRound();
        DrandQuicknetVectors.Vector memory anySig = DrandQuicknetVectors.round1();

        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundInFuture.selector, current + 1, current));
        vm.prank(anyone);
        oracle.publish(current + 1, anySig.uncompressed);
    }

    /// R15, lower bound, first invalid round: `oldestRetainedRound() - 1` is refused
    /// on the arithmetic branch, where the window floor is not clamped to 1.
    function test_RevertIf_publish_roundIsOldestMinusOne() public {
        vm.warp(DrandQuicknetVectors.round31799517().publishTime);
        uint64 oldest = oracle.oldestRetainedRound();
        DrandQuicknetVectors.Vector memory anySig = DrandQuicknetVectors.round1();

        assertGt(oldest, 1, "the window floor must be the computed one, not the clamp");

        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundTooOld.selector, oldest - 1, oldest));
        vm.prank(anyone);
        oracle.publish(oldest - 1, anySig.uncompressed);
    }

    /// R15, lower bound, last valid round: `oldestRetainedRound()` itself clears the
    /// window on the arithmetic branch. It fails later, at the pairing — which is what
    /// proves the window admitted it rather than rejecting it as too old.
    function test_publish_roundIsOldest_clearsTheWindow() public {
        vm.warp(DrandQuicknetVectors.round31799517().publishTime);
        uint64 oldest = oracle.oldestRetainedRound();
        DrandQuicknetVectors.Vector memory wrongSig = DrandQuicknetVectors.round1();

        assertGt(oldest, 1, "the window floor must be the computed one, not the clamp");

        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.InvalidSignature.selector, oldest));
        vm.prank(anyone);
        oracle.publish(oldest, wrongSig.uncompressed);
    }

    /// R1: the oracle itself refuses a genuine beacon presented for another round —
    /// the library returns false and `publish` turns that into a named revert.
    function test_RevertIf_publish_signatureBelongsToAnotherRound() public {
        DrandQuicknetVectors.Vector memory target = DrandQuicknetVectors.round1();
        DrandQuicknetVectors.Vector memory other = DrandQuicknetVectors.round8193();

        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.InvalidSignature.selector, target.round));
        vm.prank(anyone);
        oracle.publish(target.round, other.uncompressed);

        assertFalse(oracle.isPublished(target.round), "a rejected publish must write nothing");
    }
}
