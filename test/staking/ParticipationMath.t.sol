// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ParticipationMath} from "../../contracts/staking/ParticipationMath.sol";

/// @notice Conformance lock for the shared Simplex committee scalars. `quorum`/`faultTolerance` MUST stay
///         byte-equal to commonware Simplex so the on-chain halt-guard (Staking) and jail correlation
///         guard (LivenessSlashing) agree with off-chain consensus. A commonware bump that changed these
///         must fail CI here (memory dpos-liveness-slasher-design: n=21⇒q=15,f=6; n=51⇒q=35,f=16).
contract ParticipationMathTest is Test {
    function test_faultToleranceAndQuorumConformanceVectors() public pure {
        // n = 0 degenerate.
        assertEq(ParticipationMath.faultTolerance(0), 0);
        assertEq(ParticipationMath.quorum(0), 0);
        // Canonical committee sizes.
        assertEq(ParticipationMath.faultTolerance(21), 6, "f(21)");
        assertEq(ParticipationMath.quorum(21), 15, "q(21)");
        assertEq(ParticipationMath.faultTolerance(51), 16, "f(51)");
        assertEq(ParticipationMath.quorum(51), 35, "q(51)");
        // Small-set edges the halt-guard depends on.
        assertEq(ParticipationMath.quorum(1), 1);
        assertEq(ParticipationMath.quorum(3), 3); // f(3)=0 ⇒ all must sign
        assertEq(ParticipationMath.quorum(4), 3); // f(4)=1
    }

    function testFuzz_quorumIsNMinusF(uint256 n) public pure {
        n = bound(n, 1, 51);
        assertEq(ParticipationMath.quorum(n), n - ParticipationMath.faultTolerance(n));
        assertEq(ParticipationMath.faultTolerance(n), (n - 1) / 3);
    }

    function test_belowFloorPredicate() public pure {
        // 15% floor (1500 bps): seen/certs strictly below 15% is below-floor.
        assertTrue(ParticipationMath.belowFloor(14, 100, 1500), "14% < 15%");
        assertFalse(ParticipationMath.belowFloor(15, 100, 1500), "15% == floor (not below)");
        assertFalse(ParticipationMath.belowFloor(100, 100, 1500), "full participation");
        // certs == 0 ⇒ never below-floor (0 < 0 is false).
        assertFalse(ParticipationMath.belowFloor(0, 0, 1500));
    }
}
