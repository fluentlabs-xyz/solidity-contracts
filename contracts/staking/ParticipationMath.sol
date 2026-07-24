// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/// @title ParticipationMath — single source of the Simplex committee scalars used by the liveness
///        jail (LivenessSlashing), the halt-guard (Staking), and the BLEND stipend (StakingRewards).
/// @dev Kept byte-equal to commonware Simplex `quorum`/threshold so on-chain floors and off-chain
///      consensus can never disagree (memory dpos-liveness-slasher-design: n=21⇒q=15,f=6; n=51⇒q=35,f=16).
///      All `internal pure` ⇒ inlined at every call site (no predeploy, no DELEGATECALL link).
library ParticipationMath {
    /// @dev Below the participation floor over a finalized window: certs signed < `floorBps` of certs
    ///      processed. Single source for the liveness jail and the stipend passer gate.
    function belowFloor(uint32 seen, uint32 certs, uint32 floorBps) internal pure returns (bool) {
        return uint256(seen) * 10_000 < uint256(certs) * floorBps;
    }

    /// @dev Simplex fault tolerance f = ⌊(n−1)/3⌋; 0 for n==0.
    function faultTolerance(uint256 n) internal pure returns (uint256) {
        return n == 0 ? 0 : (n - 1) / 3;
    }

    /// @dev Simplex finalization quorum q(n) = n − f(n).
    function quorum(uint256 n) internal pure returns (uint256) {
        return n - faultTolerance(n);
    }
}
