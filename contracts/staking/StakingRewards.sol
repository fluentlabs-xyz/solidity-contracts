// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IStaking, IStakingEvents} from "./interfaces/IStaking.sol";
import {IChainConfig} from "./interfaces/IChainConfig.sol";
import {IBlendReserve} from "./interfaces/IBlendReserve.sol";
import {ILivenessSlashing} from "./interfaces/ILivenessSlashing.sol";
import {StakingLayout} from "./StakingLayout.sol";
import {ParticipationMath} from "./ParticipationMath.sol";

/// @title Staking BLEND stipend settlement + crediting library
/// @author Fluent Labs
/// @notice Per-epoch BLEND stipend settlement, relocated out of `Staking` (DELEGATECALL-linked) to keep
///         its runtime under EIP-170. Reached by DELEGATECALL from `Staking`'s thin `settleEpochStipend`
///         forwarder, so it shares the proxy's `msg.sender`, `address(this)`, and ERC-7201 storage. The
///         `RewardRouter` predeploy is folded away: settlement now runs inside `Staking`, so the reserve
///         disburses BLEND to (and the ledger is credited on) the same `address(this)`.
/// @dev The per-(validator,epoch) reward AMOUNTS live in `ValidatorSnapshot.totalBlendRewards`; this
///      namespace adds only the crediting audit counter + per-epoch idempotency cursor.
library StakingRewards {
    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.RewardStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant REWARD_STORAGE_LOCATION =
        0xc159fdd92bba882e73f4ae9717ef609aaa2daf501c01f90953d2b47d8e7a9d00;

    /// @custom:storage-location erc7201:Fluent.storage.RewardStorage
    struct RewardStorage {
        // Total BLEND ever credited (audit counter; <= BLEND disbursed by the reserve).
        uint256 creditedBlend;
        // (epoch + 1) per-epoch idempotency cursor. 0 == none settled.
        uint64 lastRewardedEpochP1;
    }

    function rewardStorage() internal pure returns (RewardStorage storage $) {
        assembly {
            $.slot := REWARD_STORAGE_LOCATION
        }
    }

    /// @dev Bound the per-call contiguous catch-up so a large finalized gap can never exceed the block
    ///      gas limit; a wider gap simply heals over the next calls (the cursor advances by <= this each
    ///      time and later settle(epoch) calls carry it forward).
    uint64 internal constant MAX_SETTLE_CATCHUP = 32;

    /// @dev The three DELEGATECALL deps threaded through the catch-up loop, bundled into one memory
    ///      pointer so the loop frame stays under the stack-slot limit (they are unreachable immutables).
    struct SettleDeps {
        address blendReserveAddr;
        address livenessSlashingAddr;
        IChainConfig cfg;
    }

    /// @notice Settle the per-epoch BLEND stipend: for every unsettled FINALIZED epoch up to `epoch`,
    ///         compute flat-by-stake shares among the live committee, draw them from the reserve, and
    ///         credit the ledger. Sole entry (folded from `RewardRouter.settle`); called via
    ///         `Staking.settleEpochStipend(uint64) onlySystemCall`.
    /// @dev Deps are passed as PARAMS because immutables are unreachable under DELEGATECALL. Contract:
    ///      (1) never settle past the finalized frontier (a partial participation window ⇒ wrong pass/fail
    ///      set); (2) settle CONTIGUOUSLY from the cursor (auto-heals a transient executor skip instead of
    ///      forfeiting the gap); (3) the cursor advances ONLY past an actually-settled epoch, so a replay
    ///      is a no-op that never re-draws the reserve.
    function settleEpochStipend(uint64 epoch, address blendReserveAddr, address livenessSlashingAddr, IChainConfig cfg)
        external
    {
        uint64 finalizedP1 = ILivenessSlashing(livenessSlashingAddr).lastFinalizedEpochP1();
        if (finalizedP1 == 0) return; // nothing finalized yet → wait
        uint64 upTo = finalizedP1 - 1; // finalized frontier
        if (epoch < upTo) upTo = epoch; // never settle an unfinalized window
        uint64 lo = rewardStorage().lastRewardedEpochP1; // first unsettled (0 == genesis, i.e. epoch 0 unsettled)
        if (lo != 0 && upTo + 1 <= lo) return; // stale replay / nothing new past the cursor
        SettleDeps memory deps = SettleDeps(blendReserveAddr, livenessSlashingAddr, cfg);
        for (uint64 e = lo; e <= upTo && e - lo < MAX_SETTLE_CATCHUP; e++) {
            _settleOne(e, deps);
            rewardStorage().lastRewardedEpochP1 = e + 1; // advance ONLY past a settled epoch
        }
    }

    /// @dev Settle a single finalized epoch: draw the flat-by-stake pot from the reserve and credit it.
    ///      No cursor here — `settleEpochStipend` owns idempotency/contiguity. Emits `StipendSkipped` when
    ///      the stipend is on but this finalized window credited nothing (a forfeited window, no carry-forward).
    function _settleOne(uint64 epoch, SettleDeps memory deps) private {
        // F13: one committee read for BOTH members and frozen stakes — drops the per-member `resolveSigner`
        // self-calls and the duplicate committee read inside `_blendStipendShares` (the keys leg is unused).
        (address[] memory members,, uint256[] memory stakes) =
            IStaking(address(this)).getEpochCommitteeWithStakes(epoch);

        (uint96[] memory shares, uint256 sum) = _blendStipendShares(epoch, members, stakes, deps);
        if (sum > 0) {
            uint256 sent = IBlendReserve(deps.blendReserveAddr).disburse(address(this), sum);
            // best-effort: a token-quirk short-send zeroes the BLEND leg this epoch (skip-not-revert).
            if (sent != sum) {
                shares = new uint96[](members.length);
                sum = 0;
            }
        }
        if (sum > 0) {
            _creditEpoch(epoch, members, shares);
        } else if (deps.cfg.getBlendStipendPerEpoch() > 0) {
            emit IStakingEvents.StipendSkipped(epoch);
        }
        emit IStakingEvents.EpochBlendRewardsCommitted(epoch, sum);
    }

    /// @dev BLEND stipend shares: FLAT pro-rata by STAKE. A member is included iff it met the
    ///      participation FLOOR in the finalized window AND is not tombstoned — EXCEPT on a correlated
    ///      below-floor window (belowFloor > f), a no-fault network/partition event, where the WHOLE
    ///      committee is paid (P1=A: the exact dual of the jail correlation guard in
    ///      LivenessSlashing._finalizeWindow, so a partition neither jails NOR concentrates the pot on the
    ///      ≤f above-floor minority — no farm vector). `pot` balance-clamps to the reserve. No
    ///      participation weighting, no decay, no carry-forward.
    function _blendStipendShares(
        uint64 epoch,
        address[] memory members,
        uint256[] memory stakes,
        SettleDeps memory deps
    ) private view returns (uint96[] memory shares, uint256 assigned) {
        uint256 n = members.length;
        shares = new uint96[](n);
        uint256 desired = deps.cfg.getBlendStipendPerEpoch(); // 0 = OFF (kill-switch)
        if (desired == 0) return (shares, 0);
        uint256 reserveBal = IBlendReserve(deps.blendReserveAddr).reserveBalance();
        uint256 pot = desired < reserveBal ? desired : reserveBal; // balance-clamp
        if (pot == 0) return (shares, 0);

        ILivenessSlashing liveness = ILivenessSlashing(deps.livenessSlashingAddr);
        (, uint32 windowCerts) = liveness.participation(epoch, 0); // certs is per-epoch (index-agnostic)
        if (windowCerts == 0) return (shares, 0); // empty / unfinalized window → pay nothing

        uint32 floorBps = deps.cfg.getParticipationFloorBps();
        bool[] memory passed = new bool[](n);
        uint256 belowFloor = 0;
        for (uint256 i = 0; i < n; i++) {
            (uint32 seen,) = liveness.participation(epoch, uint32(i));
            if (ParticipationMath.belowFloor(seen, windowCerts, floorBps)) belowFloor++;
            else passed[i] = true;
        }
        // Dual of the jail correlation guard: a correlated below-floor window is a no-fault network event,
        // so pay flat to the WHOLE committee rather than concentrate on the ≤f minority (P1=A).
        bool partition = belowFloor > ParticipationMath.faultTolerance(n);

        uint256[] memory passStake = new uint256[](n);
        uint256 sumStake = 0;
        for (uint256 i = 0; i < n; i++) {
            if (!(partition || passed[i])) continue; // pay-only-if-live, except a no-fault partition
            // Membership proves Active-at-E; exclude ONLY the permanent equivocation tombstone (F7),
            // read directly from storage under DELEGATECALL (no self-call).
            if (StakingLayout.equivocationStorage().tombstoned[members[i]]) continue;
            if (i >= stakes.length || stakes[i] == 0) continue;
            passStake[i] = stakes[i];
            sumStake += stakes[i];
        }
        if (sumStake == 0) return (shares, 0); // no eligible passer → pay nothing
        for (uint256 i = 0; i < n; i++) {
            if (passStake[i] == 0) continue;
            uint256 a = (pot * passStake[i]) / sumStake; // FLAT pro-rata by stake
            shares[i] = uint96(a);
            assigned += a;
        }
    }

    /// @dev Credit per-validator BLEND (already disbursed into Staking by the reserve) for `epoch`.
    ///      No cursor here — `settleEpochStipend` guards idempotency before the reserve draw.
    function _creditEpoch(uint64 epoch, address[] memory validators, uint96[] memory blendAmounts) private {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        uint256 creditedBlend = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            if (blendAmounts[i] == 0) continue;
            IStaking.Validator memory v = $._validatorsMap[validators[i]];
            if (v.status == IStaking.ValidatorStatus.NotFound) continue; // skip-not-revert
            // At-or-before materialization: E = current-2 is a PAST epoch, so copying the base params
            // from `changedAt` (a future epoch after a recent delegate/undelegate) would give the
            // per-delegator claim a wrong denominator (the F1 drain). See touchSnapshotAtOrBefore.
            StakingLayout.touchSnapshotAtOrBefore($, v, epoch).totalBlendRewards += blendAmounts[i];
            $._validatorsMap[validators[i]] = v;
            creditedBlend += blendAmounts[i];
        }
        rewardStorage().creditedBlend += creditedBlend;
    }

    /// @dev Total BLEND reward credited across `epoch`'s committee, for an off-chain APR basis.
    ///      Read-only; DELEGATECALL'd from Staking's view forwarder.
    function getEpochRewards(uint64 epoch) external view returns (uint256 blendTotal) {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        address[] storage committee = StakingLayout.epochCommitteeStorage().committee[epoch];
        for (uint256 i = 0; i < committee.length; i++) {
            blendTotal += $._validatorSnapshots[committee[i]][epoch].totalBlendRewards;
        }
    }
}
