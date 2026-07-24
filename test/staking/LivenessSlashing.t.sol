// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LivenessSlashing} from "../../contracts/staking/LivenessSlashing.sol";
import {SYSTEM_CALLER} from "../../contracts/staking/StakingContext.sol";
import {IStakingContextErrors} from "../../contracts/staking/interfaces/IStakingContext.sol";
import {IChainConfig} from "../../contracts/staking/interfaces/IChainConfig.sol";
import {IFluentGovernance} from "../../contracts/staking/interfaces/IFluentGovernance.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {IStakingPool} from "../../contracts/staking/interfaces/IStakingPool.sol";
import {ISystemReward} from "../../contracts/staking/interfaces/ISystemReward.sol";

/// @notice Mock Staking that records `slash` invocations and
///         resolves signers from a fixed per-epoch committee table.
///         Implements just the IStaking surface `LivenessSlashing` touches.
contract MockStakingForLiveness {
    mapping(uint64 epoch => mapping(uint32 signerIdx => address)) public committee;
    mapping(uint64 epoch => uint256) public committeeSize;
    address[] public slashed;

    function setSigner(uint64 epoch, uint32 signerIdx, address validator) external {
        committee[epoch][signerIdx] = validator;
    }

    /// Set the committed committee length for `epoch` (P2-5 cross-check:
    /// `processBitmap`'s `committeeSize` must equal `getEpochCommittee(epoch).length`).
    function setCommitteeSize(uint64 epoch, uint256 size) external {
        committeeSize[epoch] = size;
    }

    function getEpochCommittee(uint64 epoch) external view returns (address[] memory) {
        return new address[](committeeSize[epoch]);
    }

    function getEpochCommitteeLength(uint64 epoch) external view returns (uint256) {
        return committeeSize[epoch];
    }

    function resolveSigner(uint64 epoch, uint32 signerIdx) external view returns (address) {
        return committee[epoch][signerIdx];
    }

    function slash(address validator) external {
        slashed.push(validator);
    }

    function slashedLength() external view returns (uint256) {
        return slashed.length;
    }

    uint256 public readmitCalls;

    function readmitExpiredJails(uint64) external {
        readmitCalls += 1;
    }
}

/// @notice Mock ChainConfig exposing just the two getters `LivenessSlashing`
///         reads for `_currentEpochAt` (P2-5 epoch-window check).
contract MockChainConfigForLiveness {
    uint64 public dposActivationBlock;
    uint32 public epochBlockInterval;
    uint32 public participationFloorBps = 1500;
    bool public participationJailDisabled;

    constructor(uint64 activation, uint32 interval) {
        dposActivationBlock = activation;
        epochBlockInterval = interval;
    }

    function getDposActivationBlock() external view returns (uint64) {
        return dposActivationBlock;
    }

    function getEpochBlockInterval() external view returns (uint32) {
        return epochBlockInterval;
    }

    function getParticipationFloorBps() external view returns (uint32) {
        return participationFloorBps;
    }

    function setParticipationFloorBps(uint32 v) external {
        participationFloorBps = v;
    }

    function getParticipationJailDisabled() external view returns (bool) {
        return participationJailDisabled;
    }

    function setParticipationJailDisabled(bool v) external {
        participationJailDisabled = v;
    }
}

/// @notice Unit tests for `LivenessSlashing.processBitmap` (windowed participation model).
contract LivenessSlashingTest is Test {
    LivenessSlashing internal liveness;
    MockStakingForLiveness internal mockStaking;
    MockChainConfigForLiveness internal mockChainConfig;

    /// Epoch length used by the mock ChainConfig. Large enough that each test's intra-epoch block
    /// offsets stay inside one epoch, so `_epochAt(block) == epoch` for `_block(epoch, offset)`.
    uint64 internal constant INTERVAL = 1000;
    /// Default participation floor exposed by the mock ChainConfig (15%).
    uint32 internal constant FLOOR_BPS = 1500;

    function setUp() public {
        mockStaking = new MockStakingForLiveness();
        mockChainConfig = new MockChainConfigForLiveness(0, uint32(INTERVAL));
        // Other StakingContext deps are unused in the liveness path — pass
        // anything castable to the right type.
        LivenessSlashing impl = new LivenessSlashing(
            IStaking(address(mockStaking)),
            ISystemReward(payable(address(0xdead))),
            IStakingPool(payable(address(0xdead))),
            IFluentGovernance(address(0xdead)),
            IChainConfig(address(mockChainConfig)),
            IERC20(address(0xdead))
        );
        liveness = LivenessSlashing(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(LivenessSlashing.initialize, (address(this)))))
        );
    }

    /// @notice Build a bitmap of `committeeSize` bits with one given index unset.
    function _allPresentExcept(uint8 committeeSize, uint8 absentIdx) internal pure returns (bytes memory) {
        uint256 len = (uint256(committeeSize) + 7) / 8;
        bytes memory b = new bytes(len);
        for (uint8 i = 0; i < committeeSize; i++) {
            if (i != absentIdx) {
                b[i >> 3] |= bytes1(uint8(1 << (i & 7)));
            }
        }
        return b;
    }

    function _allPresent(uint8 committeeSize) internal pure returns (bytes memory) {
        uint256 len = (uint256(committeeSize) + 7) / 8;
        bytes memory b = new bytes(len);
        for (uint8 i = 0; i < committeeSize; i++) {
            b[i >> 3] |= bytes1(uint8(1 << (i & 7)));
        }
        return b;
    }

    /// Bitmap with every index present EXCEPT those in `absent`.
    function _absentSet(uint8 committeeSize, uint8[] memory absent) internal pure returns (bytes memory b) {
        uint256 len = (uint256(committeeSize) + 7) / 8;
        b = new bytes(len);
        for (uint8 i = 0; i < committeeSize; i++) {
            bool isAbsent = false;
            for (uint256 j = 0; j < absent.length; j++) {
                if (absent[j] == i) {
                    isAbsent = true;
                    break;
                }
            }
            if (!isAbsent) b[i >> 3] |= bytes1(uint8(1 << (i & 7)));
        }
    }

    /// Block number inside `epoch` at the given intra-epoch `offset`, so `_epochAt(block) == epoch`.
    function _block(uint64 epoch, uint64 offset) internal pure returns (uint64) {
        return epoch * INTERVAL + offset;
    }

    /// Drive `processBitmap` for `epoch` at intra-epoch block `offset`, keeping the mock's committed
    /// committee length in sync so the size cross-check passes.
    function _process(uint64 epoch, uint64 offset, uint8 committeeSize, bytes memory bitmap) internal {
        mockStaking.setCommitteeSize(epoch, committeeSize);
        vm.prank(SYSTEM_CALLER);
        liveness.processBitmap(epoch, _block(epoch, offset), committeeSize, bitmap);
    }

    /// Advance the block clock into `atEpoch` with one trivial all-present cert so the finalize
    /// catch-up loop runs for every window <= atEpoch - 2. `atEpoch`'s own accumulation is harmless.
    function _advanceToEpoch(uint64 atEpoch) internal {
        _process(atEpoch, 1, 8, _allPresent(8));
    }

    /// A below-floor member (seen == 0) is jailed only once its window is finalized at E+2.
    function test_belowFloorMemberJailedAtFinalize() public {
        address victim = makeAddr("victim");
        mockStaking.setSigner(5, 2, victim);
        bytes memory miss = _allPresentExcept(8, 2);
        for (uint64 k = 1; k <= 10; k++) {
            _process(5, k, 8, miss);
        }
        (uint32 seen, uint32 certs) = liveness.participation(5, 2);
        assertEq(seen, 0);
        assertEq(certs, 10);
        // Window 5 is not yet closed at block-epoch 5, so nothing is slashed.
        assertEq(mockStaking.slashedLength(), 0);

        _advanceToEpoch(7); // block-epoch 7 => window 5 (7-2) finalizes
        assertEq(mockStaking.slashedLength(), 1);
        assertEq(mockStaking.slashed(0), victim);
    }

    /// A member at/above the floor is never slashed.
    function test_aboveFloorMemberNotSlashed() public {
        bytes memory all = _allPresent(8);
        for (uint64 k = 1; k <= 5; k++) {
            _process(5, k, 8, all);
        }
        _advanceToEpoch(7);
        assertEq(mockStaking.slashedLength(), 0);
    }

    /// Correlation guard: > f simultaneous below-floor members ⇒ the whole window is skipped.
    function test_correlationGuardSkipsMassFailure() public {
        // committeeSize 8 ⇒ f = (8-1)/3 = 2; three below-floor members exceeds f.
        uint8[] memory absent = new uint8[](3);
        absent[0] = 0;
        absent[1] = 1;
        absent[2] = 2;
        bytes memory b = _absentSet(8, absent);
        for (uint64 k = 1; k <= 10; k++) {
            _process(5, k, 8, b);
        }
        _advanceToEpoch(7);
        assertEq(mockStaking.slashedLength(), 0, "mass failure must be treated as a network event");
    }

    /// An empty window (no certs processed) is judged as nothing.
    function test_emptyWindowNoSlash() public {
        _advanceToEpoch(7); // finalizes windows 0..5, all empty
        assertEq(mockStaking.slashedLength(), 0);
    }

    /// F9: a cert stamped with an epoch outside {current, current-1} is skipped (not accumulated).
    function test_staleEpochTagSkipped() public {
        mockStaking.setCommitteeSize(2, 8);
        bytes memory miss = _allPresentExcept(8, 3);
        vm.prank(SYSTEM_CALLER);
        liveness.processBitmap(2, _block(9, 1), 8, miss);
        (, uint32 certs) = liveness.participation(2, 3);
        assertEq(certs, 0, "stale-epoch accounting must be skipped");
    }

    /// The prev-epoch boundary (epoch == current-1) IS in-window and still accumulates.
    function test_prevEpochBoundaryInWindow() public {
        mockStaking.setCommitteeSize(8, 8);
        bytes memory miss = _allPresentExcept(8, 3);
        vm.prank(SYSTEM_CALLER);
        liveness.processBitmap(8, _block(9, 0), 8, miss);
        (uint32 seen, uint32 certs) = liveness.participation(8, 3);
        assertEq(certs, 1, "current-1 epoch must still be accounted");
        assertEq(seen, 0);
    }

    /// F9: a late cert for epoch E arriving at block-epoch E+1 is still counted before E finalizes.
    function test_lateCurrentMinus1CertCountedBeforeFinalize() public {
        address victim = makeAddr("victim");
        mockStaking.setSigner(5, 2, victim);
        bytes memory miss = _allPresentExcept(8, 2);
        for (uint64 k = 1; k <= 5; k++) {
            _process(5, k, 8, miss); // certs at block-epoch 5
        }
        // Late cert for epoch 5 at a block in epoch 6 (the current-1 boundary) — still counted.
        mockStaking.setCommitteeSize(5, 8);
        vm.prank(SYSTEM_CALLER);
        liveness.processBitmap(5, _block(6, 1), 8, miss);
        (, uint32 certs) = liveness.participation(5, 2);
        assertEq(certs, 6, "late current-1 cert must be counted");
        // Window 5 is not finalized at block-epoch 6 (target = 4).
        assertEq(mockStaking.slashedLength(), 0);

        _advanceToEpoch(7);
        assertEq(mockStaking.slashedLength(), 1);
        assertEq(mockStaking.slashed(0), victim);
    }

    /// Finalize catches up across skipped epochs: a below-floor window is still judged after a jump.
    function test_finalizeCatchUpOverSkippedEpochs() public {
        address victim = makeAddr("victim");
        mockStaking.setSigner(5, 2, victim);
        bytes memory miss = _allPresentExcept(8, 2);
        for (uint64 k = 1; k <= 10; k++) {
            _process(5, k, 8, miss);
        }
        _advanceToEpoch(10); // jump; catch-up finalizes 0..8, window 5 judged
        assertEq(mockStaking.slashedLength(), 1);
        assertEq(mockStaking.slashed(0), victim);
    }

    /// The participation floor is read from ChainConfig, not a constant: a 50% floor jails a member
    /// that a 15% floor would leave alone.
    function test_participationFloorIsConfigDriven() public {
        mockChainConfig.setParticipationFloorBps(5000); // 50%
        address victim = makeAddr("victim");
        mockStaking.setSigner(5, 2, victim);
        // signer 2 present in 4 of 10 certs (40%) — below a 50% floor, above a 15% one.
        for (uint64 k = 1; k <= 10; k++) {
            bytes memory b = k <= 4 ? _allPresent(8) : _allPresentExcept(8, 2);
            _process(5, k, 8, b);
        }
        _advanceToEpoch(7);
        assertEq(mockStaking.slashedLength(), 1);
        assertEq(mockStaking.slashed(0), victim);
    }

    /// Kill switch OFF: a below-floor member's window still finalizes (cursor advances) and its
    /// counters still accumulate, but no jail is dispatched.
    function test_jailDisabledSkipsJailButKeepsCounters() public {
        mockChainConfig.setParticipationJailDisabled(true);
        address victim = makeAddr("victim");
        mockStaking.setSigner(5, 2, victim);
        bytes memory miss = _allPresentExcept(8, 2);
        for (uint64 k = 1; k <= 10; k++) {
            _process(5, k, 8, miss);
        }
        _advanceToEpoch(7); // block-epoch 7 => window 5 finalizes
        // Counters accumulated exactly as when enabled...
        (uint32 seen, uint32 certs) = liveness.participation(5, 2);
        assertEq(seen, 0);
        assertEq(certs, 10);
        // ...but the window is judged as nothing — no jail dispatched.
        assertEq(mockStaking.slashedLength(), 0, "jail must not fire while disabled");
        // The finalize cursor still advanced past the window.
        assertEq(liveness.lastFinalizedEpoch(), 5);
    }

    /// Re-enabling judges SUBSEQUENT windows again, but never retro-judges windows finalized
    /// while the switch was off (the cursor already moved past them).
    function test_reEnableDoesNotRetroJudgeSkippedWindows() public {
        // Window 5: below-floor victim, judged while DISABLED → never jailed, cursor past 5.
        mockChainConfig.setParticipationJailDisabled(true);
        address victim5 = makeAddr("victim5");
        mockStaking.setSigner(5, 2, victim5);
        bytes memory miss5 = _allPresentExcept(8, 2);
        for (uint64 k = 1; k <= 10; k++) {
            _process(5, k, 8, miss5);
        }
        _advanceToEpoch(7); // finalizes windows <=5 while disabled
        assertEq(mockStaking.slashedLength(), 0);
        assertEq(liveness.lastFinalizedEpoch(), 5);

        // Re-enable and drive a fresh below-floor window 7 → judged again.
        mockChainConfig.setParticipationJailDisabled(false);
        address victim7 = makeAddr("victim7");
        mockStaking.setSigner(7, 3, victim7);
        bytes memory miss7 = _allPresentExcept(8, 3);
        for (uint64 k = 1; k <= 10; k++) {
            _process(7, k, 8, miss7);
        }
        _advanceToEpoch(9); // finalizes windows 6..7 with the jail re-armed
        // Only the post-re-enable window is jailed; window 5 stays permanently unjudged.
        assertEq(mockStaking.slashedLength(), 1, "only the re-enabled window is judged");
        assertEq(mockStaking.slashed(0), victim7);
    }

    /// Same `blockNumber` called twice → second call is a no-op (no double accumulation).
    function test_idempotencySameBlockNoOp() public {
        bytes memory all = _allPresent(8);
        _process(5, 5, 8, all);
        (, uint32 certs1) = liveness.participation(5, 0);
        _process(5, 5, 8, all); // same blockNumber → guard returns early
        (, uint32 certs2) = liveness.participation(5, 0);
        assertEq(certs1, 1);
        assertEq(certs2, 1);
        assertEq(liveness.lastProcessedBlock(), _block(5, 5));
    }

    /// `readmitExpiredJails` is invoked on every fresh block (auto-reinstate sweep).
    function test_readmitSweepRunsEachBlock() public {
        bytes memory all = _allPresent(8);
        _process(5, 1, 8, all);
        _process(5, 2, 8, all);
        assertEq(mockStaking.readmitCalls(), 2);
    }

    /// `signersBitmap.length != ceil(committeeSize/8)` → revert with `InvalidBitmapLength`.
    function test_invalidBitmapLengthReverts() public {
        mockStaking.setCommitteeSize(7, 8);
        bytes memory bad = new bytes(2); // committeeSize=8 expects 1 byte
        vm.prank(SYSTEM_CALLER);
        vm.expectRevert(LivenessSlashing.InvalidBitmapLength.selector);
        liveness.processBitmap(7, _block(7, 1), 8, bad);
    }

    /// A cert whose committeeSize disagrees with the committed committee length is skipped.
    function test_committeeSizeMismatchSkipped() public {
        mockStaking.setCommitteeSize(7, 8);
        bytes memory bitmap = new bytes(2); // ceil(16/8) = 2 bytes
        vm.prank(SYSTEM_CALLER);
        liveness.processBitmap(7, _block(7, 1), 16, bitmap);
        (, uint32 certs) = liveness.participation(7, 0);
        assertEq(certs, 0, "size-mismatch accounting must be skipped");
    }

    /// `committeeSize == 0` → early return (cold-start / no-prev-cert); idempotency guard not armed.
    function test_committeeSizeZeroEarlyReturns() public {
        bytes memory empty;
        vm.prank(SYSTEM_CALLER);
        liveness.processBitmap(7, _block(7, 42), 0, empty);
        assertEq(liveness.lastProcessedBlock(), 0);
    }

    /// `onlySystemCall` rejects callers other than the EIP-4788 sentinel.
    function test_onlySystemCallRejectsEoa() public {
        bytes memory b = _allPresent(8);
        vm.expectRevert(IStakingContextErrors.OnlySystemCall.selector);
        liveness.processBitmap(7, 1, 8, b);
    }
}

/// @notice ACL test for `Staking.slash` — reverts when called
///         from any address other than the configured `_livenessSlashingAddr`.
///         Constructed against the real `Staking` contract (no mocking) so
///         the modifier is exercised end-to-end.
contract StakingSlashFromLivenessAclTest is Test {
    function test_slash_rejects_non_liveness_caller() public {
        // The minimum viable deploy is just `Staking` with predicted
        // self-address + `address(0)` placeholders for unused deps. The
        // `onlyFromLivenessSlashing` modifier runs BEFORE `_slashValidator`,
        // so the rest of the surface never executes.
        //
        // This intentionally exercises only the modifier; richer slashing
        // semantics are covered by `Staking.t.sol` proper.
        address livenessAddr = makeAddr("liveness");
        address rogueCaller = makeAddr("rogue");

        // Stand up Staking impl with `livenessAddr` set as the ACL'd caller.
        // Use minimal predicted-address scaffold (we never call the rest of
        // the staking surface, so address(this) substitutes for predictions).
        //
        // NB: full deploy here would duplicate ~150 LOC of test setup; the
        // critical assertion is the revert on rogue caller, which only
        // needs the constructor to wire `_livenessSlashingAddr`.
        bytes memory deploy = abi.encodePacked(type(_StakingMinDeploy).creationCode, abi.encode(livenessAddr));
        address stakingImpl;
        assembly {
            stakingImpl := create(0, add(deploy, 0x20), mload(deploy))
        }
        require(stakingImpl != address(0), "staking impl deploy failed");

        // Even at the impl level, the modifier rejects unauthorized callers.
        vm.prank(rogueCaller);
        vm.expectRevert(IStakingContextErrors.OnlyLivenessSlashing.selector);
        _StakingMinDeploy(stakingImpl).slash(makeAddr("victim"));
    }
}

/// @notice Tiny standalone contract that mirrors `Staking`'s
///         `onlyFromLivenessSlashing` modifier + `slash`
///         entry-point so the ACL is testable without the full Staking
///         deploy harness. NOT intended for production — exists only as a
///         test fixture for `StakingSlashFromLivenessAclTest`.
contract _StakingMinDeploy is IStakingContextErrors {
    address private immutable _livenessSlashingAddr;

    constructor(address livenessSlashingAddr) {
        _livenessSlashingAddr = livenessSlashingAddr;
    }

    modifier onlyFromLivenessSlashing() {
        require(msg.sender == _livenessSlashingAddr, OnlyLivenessSlashing());
        _;
    }

    function slash(address) external onlyFromLivenessSlashing {
        // no-op for ACL test
    }
}
