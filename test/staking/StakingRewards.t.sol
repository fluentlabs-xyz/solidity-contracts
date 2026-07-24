// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {StakingRewards} from "../../contracts/staking/StakingRewards.sol";
import {StakingLayout} from "../../contracts/staking/StakingLayout.sol";
import {IStaking, IStakingEvents} from "../../contracts/staking/interfaces/IStaking.sol";
import {IChainConfig} from "../../contracts/staking/interfaces/IChainConfig.sol";

/// @notice Library-context harness for `StakingRewards.settleEpochStipend`. It hosts the DELEGATECALL
///         storage context AND implements the `IStaking` reads the library calls back into via
///         `IStaking(address(this))`, so the folded settlement can be exercised without a full proxy.
contract StipendHarness {
    address[] internal _members;
    uint256[] internal _stakes;

    function setCommittee(address[] calldata members, uint256[] calldata stakes) external {
        delete _members;
        delete _stakes;
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        for (uint256 i = 0; i < members.length; i++) {
            _members.push(members[i]);
            _stakes.push(stakes[i]);
            // Register so _creditEpoch's NotFound skip does not drop the credit.
            IStaking.Validator memory v = $._validatorsMap[members[i]];
            v.validatorAddress = members[i];
            v.status = IStaking.ValidatorStatus.Active;
            $._validatorsMap[members[i]] = v;
        }
    }

    // --- IStaking reads the library calls back into (via IStaking(address(this))) ---

    function getEpochCommitteeLength(uint64) external view returns (uint256) {
        return _members.length;
    }

    function resolveSigner(uint64, uint32 idx) external view returns (address) {
        return _members[idx];
    }

    function getEpochCommitteeWithStakes(uint64)
        external
        view
        returns (address[] memory addrs, bytes[] memory, uint256[] memory stakes)
    {
        return (_members, new bytes[](0), _stakes);
    }

    function getValidatorStatus(address)
        external
        pure
        returns (address, uint8, uint256, uint32, uint64, uint64, uint64, uint16)
    {
        return (address(0), uint8(IStaking.ValidatorStatus.Active), 0, 0, 0, 0, 0, 0);
    }

    // --- settlement entry + readers ---

    function settle(uint64 epoch, address reserve, address liveness, IChainConfig cfg) external {
        StakingRewards.settleEpochStipend(epoch, reserve, liveness, cfg);
    }

    function creditedBlendOf(address v, uint64 epoch) external view returns (uint96) {
        return StakingLayout.stakingStorage()._validatorSnapshots[v][epoch].totalBlendRewards;
    }

    function lastSettledEpochP1() external view returns (uint64) {
        return StakingRewards.rewardStorage().lastRewardedEpochP1;
    }

    /// Pre-advance the settlement cursor so a test can drive a single target epoch without the
    /// contiguous catch-up sweeping every epoch from genesis.
    function setSettledCursor(uint64 v) external {
        StakingRewards.rewardStorage().lastRewardedEpochP1 = v;
    }

    /// Set the permanent equivocation tombstone (the only fault the stipend gate now excludes).
    function setTombstoned(address v, bool t) external {
        StakingLayout.equivocationStorage().tombstoned[v] = t;
    }
}

contract MockChainConfigForStipend {
    uint32 public participationFloorBps = 1500;
    uint256 public blendStipendPerEpoch;

    function getParticipationFloorBps() external view returns (uint32) {
        return participationFloorBps;
    }

    function getBlendStipendPerEpoch() external view returns (uint256) {
        return blendStipendPerEpoch;
    }

    function setBlendStipendPerEpoch(uint256 v) external {
        blendStipendPerEpoch = v;
    }
}

contract MockLivenessForStipend {
    uint32 public certs;
    uint64 public finalizedP1;
    mapping(uint32 => uint32) public seenOf;

    function setCerts(uint32 c) external {
        certs = c;
    }

    function setSeen(uint32 idx, uint32 seen) external {
        seenOf[idx] = seen;
    }

    function setFinalizedP1(uint64 v) external {
        finalizedP1 = v;
    }

    function participation(uint64, uint32 idx) external view returns (uint32 seen, uint32 c) {
        return (seenOf[idx], certs);
    }

    function lastFinalizedEpochP1() external view returns (uint64) {
        return finalizedP1;
    }

    function lastFinalizedEpoch() external view returns (uint64) {
        return finalizedP1 == 0 ? 0 : finalizedP1 - 1;
    }
}

contract MockReserveForStipend {
    uint256 public bal;
    uint256 public lastDisbursed;
    uint256 public disburseCalls;

    function setBalance(uint256 b) external {
        bal = b;
    }

    function reserveBalance() external view returns (uint256) {
        return bal;
    }

    function disburse(address, uint256 amount) external returns (uint256 sent) {
        sent = amount < bal ? amount : bal;
        lastDisbursed = sent;
        disburseCalls += 1;
    }
}

contract StakingRewardsTest is Test {
    StipendHarness internal harness;
    MockChainConfigForStipend internal cfg;
    MockLivenessForStipend internal liveness;
    MockReserveForStipend internal reserve;

    address internal v0 = makeAddr("v0");
    address internal v1 = makeAddr("v1");
    address internal v2 = makeAddr("v2");

    function setUp() public {
        harness = new StipendHarness();
        cfg = new MockChainConfigForStipend();
        liveness = new MockLivenessForStipend();
        reserve = new MockReserveForStipend();

        address[] memory members = new address[](3);
        members[0] = v0;
        members[1] = v1;
        members[2] = v2;
        uint256[] memory stakes = new uint256[](3);
        stakes[0] = 100;
        stakes[1] = 200;
        stakes[2] = 300;
        harness.setCommittee(members, stakes);
    }

    /// Drive settlement for a SINGLE target `epoch`: finalize it and pre-advance the cursor so the
    /// contiguous catch-up settles only `epoch`.
    function _settleOne(uint64 epoch) internal {
        liveness.setFinalizedP1(epoch + 1);
        harness.setSettledCursor(epoch);
        harness.settle(epoch, address(reserve), address(liveness), IChainConfig(address(cfg)));
    }

    function _allSeen(uint32 c) internal {
        liveness.setCerts(c);
        liveness.setSeen(0, c);
        liveness.setSeen(1, c);
        liveness.setSeen(2, c);
    }

    /// BLEND stipend: FLAT pro-rata by stake among live passers, credited per validator.
    function test_blendStipendFlatByStake() public {
        cfg.setBlendStipendPerEpoch(600);
        reserve.setBalance(10_000);
        _allSeen(10);
        _settleOne(1);
        // stakes [100,200,300] sum 600 ⇒ shares [100,200,300].
        assertEq(harness.creditedBlendOf(v0, 1), 100);
        assertEq(harness.creditedBlendOf(v1, 1), 200);
        assertEq(harness.creditedBlendOf(v2, 1), 300);
        assertEq(reserve.lastDisbursed(), 600);
    }

    /// Build an 8-member committee (stake 100 each) so the correlation guard has room: f(8)=2.
    function _committee8() internal returns (address[] memory members) {
        members = new address[](8);
        uint256[] memory stakes = new uint256[](8);
        for (uint256 i = 0; i < 8; i++) {
            members[i] = makeAddr(string(abi.encodePacked("m", vm.toString(i))));
            stakes[i] = 100;
        }
        harness.setCommittee(members, stakes);
    }

    /// F6: individual downtime (belowFloor <= f) keeps "pay only if live" — the below-floor member is not
    /// paid; the live majority splits the pot.
    function test_individualDowntimeNotPaid() public {
        address[] memory m = _committee8();
        cfg.setBlendStipendPerEpoch(700);
        reserve.setBalance(10_000);
        liveness.setCerts(10);
        for (uint32 i = 0; i < 7; i++) {
            liveness.setSeen(i, 10); // 7 passers
        }
        liveness.setSeen(7, 0); // 1 below floor (belowFloor=1 <= f(8)=2 ⇒ NOT a partition)
        _settleOne(1);
        for (uint256 i = 0; i < 7; i++) {
            assertEq(harness.creditedBlendOf(m[i], 1), 100, "live member paid its flat share");
        }
        assertEq(harness.creditedBlendOf(m[7], 1), 0, "below-floor individual is not paid");
    }

    /// F6 (P1=A): a correlated below-floor window (belowFloor > f) is a no-fault partition — pay flat to the
    /// WHOLE committee, NOT the above-floor minority (kills the concentration/farm vector).
    function test_partitionPaysWholeCommittee() public {
        address[] memory m = _committee8();
        cfg.setBlendStipendPerEpoch(800);
        reserve.setBalance(10_000);
        liveness.setCerts(10);
        for (uint32 i = 0; i < 5; i++) {
            liveness.setSeen(i, 10); // 5 above floor
        }
        liveness.setSeen(5, 0);
        liveness.setSeen(6, 0);
        liveness.setSeen(7, 0); // 3 below floor (belowFloor=3 > f(8)=2 ⇒ PARTITION)
        _settleOne(1);
        for (uint256 i = 0; i < 8; i++) {
            assertEq(harness.creditedBlendOf(m[i], 1), 100, "partition pays the whole committee flat-by-stake");
        }
    }

    /// Balance-clamp: stipend pot clamps to the reserve balance and drains gracefully.
    function test_blendStipendBalanceClamp() public {
        cfg.setBlendStipendPerEpoch(1000);
        reserve.setBalance(300); // less than desired
        _allSeen(10);
        _settleOne(1);
        // pot clamps to 300 ⇒ shares [50,100,150].
        assertEq(harness.creditedBlendOf(v0, 1), 50);
        assertEq(harness.creditedBlendOf(v1, 1), 100);
        assertEq(harness.creditedBlendOf(v2, 1), 150);
    }

    /// F3: settle is idempotent — a stale/duplicate epoch is a no-op and never re-draws the reserve.
    function test_settleIdempotent() public {
        cfg.setBlendStipendPerEpoch(600);
        reserve.setBalance(10_000);
        _allSeen(10);
        _settleOne(2);
        assertEq(reserve.disburseCalls(), 1);
        assertEq(harness.creditedBlendOf(v0, 2), 100);
        // duplicate epoch (finalized, cursor already past 2) → no-op
        liveness.setFinalizedP1(3);
        harness.settle(2, address(reserve), address(liveness), IChainConfig(address(cfg)));
        assertEq(reserve.disburseCalls(), 1, "duplicate epoch must not re-draw the reserve");
        // stale epoch below the cursor → no-op
        harness.settle(1, address(reserve), address(liveness), IChainConfig(address(cfg)));
        assertEq(reserve.disburseCalls(), 1, "stale epoch must not re-draw the reserve");
    }

    /// Stipend OFF (blendStipendPerEpoch == 0) ⇒ nothing disbursed, cursor still advances.
    function test_stipendOffCreditsNothing() public {
        _settleOne(1);
        assertEq(reserve.disburseCalls(), 0);
        assertEq(harness.lastSettledEpochP1(), 2, "cursor advanced past the settled epoch");
    }

    /// F3: never settle past the finalized frontier — a settle call for an unfinalized epoch waits.
    function test_settleBeforeFinalizedWaits() public {
        cfg.setBlendStipendPerEpoch(600);
        reserve.setBalance(10_000);
        _allSeen(10);
        liveness.setFinalizedP1(0); // nothing finalized
        harness.settle(5, address(reserve), address(liveness), IChainConfig(address(cfg)));
        assertEq(reserve.disburseCalls(), 0, "unfinalized epoch must wait");
        assertEq(harness.lastSettledEpochP1(), 0, "cursor unmoved while nothing finalized");

        // Only epoch 2 finalized: settling target 5 clamps to the finalized frontier (settles 0..2).
        liveness.setFinalizedP1(3);
        harness.settle(5, address(reserve), address(liveness), IChainConfig(address(cfg)));
        assertEq(harness.lastSettledEpochP1(), 3, "settled contiguously up to the finalized frontier only");
        assertEq(reserve.disburseCalls(), 3, "epochs 0,1,2 each settled once");
    }

    /// F3: a gap heals — a jump call settles every unsettled finalized epoch contiguously, no forfeiture.
    function test_settleContiguousCatchUp() public {
        cfg.setBlendStipendPerEpoch(600);
        reserve.setBalance(10_000);
        _allSeen(10);
        liveness.setFinalizedP1(6); // epochs 0..5 finalized
        // Executor "skips" ahead and calls settle(5) directly; the contiguous loop settles 0..5.
        harness.settle(5, address(reserve), address(liveness), IChainConfig(address(cfg)));
        assertEq(reserve.disburseCalls(), 6, "all six finalized epochs settled (gap healed)");
        assertEq(harness.lastSettledEpochP1(), 6, "cursor advanced past epoch 5");
        for (uint64 e = 0; e <= 5; e++) {
            assertEq(harness.creditedBlendOf(v0, e), 100, "each epoch credited its share");
        }
    }

    /// F7: the gate excludes ONLY the permanent equivocation tombstone; a member that passed the floor
    /// at E but was liveness-jailed afterwards still earns its E stipend, while a tombstoned one forfeits.
    function test_tombstonedForfeitsButJailedStillPaid() public {
        cfg.setBlendStipendPerEpoch(600);
        reserve.setBalance(10_000);
        _allSeen(10);
        harness.setTombstoned(v1, true); // v1 equivocated → excluded; v0/v2 (jailed-later is irrelevant) paid
        _settleOne(1);
        // v1 excluded ⇒ only v0(100)+v2(300)=400 stake share the 600 pot: v0=150, v2=450.
        assertEq(harness.creditedBlendOf(v0, 1), 150, "floor-passer still paid despite any later liveness jail");
        assertEq(harness.creditedBlendOf(v1, 1), 0, "tombstoned member forfeits");
        assertEq(harness.creditedBlendOf(v2, 1), 450);
    }

    /// F3: `StipendSkipped` fires when the stipend is on but a finalized window credited nothing — here an
    /// empty finalized window (zero certs processed), which pays nobody and has no carry-forward.
    function test_stipendSkippedEventOnForfeitedWindow() public {
        cfg.setBlendStipendPerEpoch(600);
        reserve.setBalance(10_000);
        liveness.setCerts(0); // finalized but empty window ⇒ nothing to pay
        liveness.setFinalizedP1(1);
        harness.setSettledCursor(0);
        vm.expectEmit(true, false, false, false, address(harness));
        emit IStakingEvents.StipendSkipped(0);
        harness.settle(0, address(reserve), address(liveness), IChainConfig(address(cfg)));
    }
}
