// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ChainConfig} from "../../contracts/staking/ChainConfig.sol";
import {Staking} from "../../contracts/staking/Staking.sol";
import {MockStakingRewardInjector} from "../../contracts/staking/mocks/MockStakingRewardInjector.sol";
import {StakingPool} from "../../contracts/staking/StakingPool.sol";
import {SystemReward} from "../../contracts/staking/SystemReward.sol";
import {MockBlendToken} from "../../contracts/staking/mocks/MockBlendToken.sol";
import {IChainConfig} from "../../contracts/staking/interfaces/IChainConfig.sol";
import {IFluentGovernance} from "../../contracts/staking/interfaces/IFluentGovernance.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {IStakingPool} from "../../contracts/staking/interfaces/IStakingPool.sol";
import {ISystemReward} from "../../contracts/staking/interfaces/ISystemReward.sol";

/// @notice Finding A regression lock: delegator reward FORFEITURE across a bounded (chunked) claim.
///
/// Bug (pre-fix, StakingEconomics._claimDelegatorRewardsAndPendingUndelegates outer-loop tail): after
/// the inner accrual loop the code UNCONDITIONALLY delete+advanced a non-last delegate op, even when the
/// inner loop stopped at the claim bound `B` (before the next op's epoch `E2`). Epochs `[B, E2)` at that
/// op's amount were then dropped forever — the next claim resumed at the next op (epoch E2). The 1000-epoch
/// per-claim cap (`_cappedDelegatorClaimEpoch`) is an amplifier: it forces `B < E2` even on ordinary
/// full-range claims of a long-idle first op.
///
/// Fix: when the inner loop stopped at `B` (`delegateOp.epoch < voteChangedAtEpoch`), PRESERVE the op with
/// its epoch advanced to `B` and break (mirror of the last-op preserve branch); only when it stopped at E2
/// (op fully consumed) does the delete+advance still run. These tests would strand reward pre-fix and
/// recover it fully post-fix.
contract AuditFindingATest is Test {
    uint256 internal constant ONE = 1 ether;

    MockStakingRewardInjector internal staking;
    ChainConfig internal chainConfig;
    MockBlendToken internal blend;

    address internal validatorV = makeAddr("validatorV");

    function setUp() public {
        blend = new MockBlendToken();
        blend.mint(address(this), 1_000_000 ether);
        blend.mint(validatorV, 1_000_000 ether);

        uint64 nonce = vm.getNonce(address(this));
        IStaking predictedStaking = IStaking(vm.computeCreateAddress(address(this), nonce + 1));
        ISystemReward predictedSystemReward = ISystemReward(vm.computeCreateAddress(address(this), nonce + 3));
        IStakingPool predictedStakingPool = IStakingPool(vm.computeCreateAddress(address(this), nonce + 5));
        IChainConfig predictedChainConfig = IChainConfig(vm.computeCreateAddress(address(this), nonce + 7));
        IFluentGovernance governance = IFluentGovernance(address(this));

        MockStakingRewardInjector stakingImpl = new MockStakingRewardInjector(
            predictedStaking,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig,
            blend,
            address(0),
            address(0)
        );
        staking = MockStakingRewardInjector(
            payable(
                address(
                    new ERC1967Proxy(
                        address(stakingImpl),
                        abi.encodeCall(Staking.initialize, (address(this), new address[](0), new uint256[](0), uint16(0)))
                    )
                )
            )
        );

        SystemReward systemRewardImpl = new SystemReward(
            predictedStaking, predictedSystemReward, predictedStakingPool, governance, predictedChainConfig, blend
        );
        new ERC1967Proxy(
            address(systemRewardImpl),
            abi.encodeCall(SystemReward.initialize, (address(this), _singleton(address(this)), _singleton16(10_000)))
        );

        StakingPool stakingPoolImpl = new StakingPool(
            predictedStaking, predictedSystemReward, predictedStakingPool, governance, predictedChainConfig, blend
        );
        new ERC1967Proxy(address(stakingPoolImpl), abi.encodeCall(StakingPool.initialize, (address(this))));

        ChainConfig chainConfigImpl = new ChainConfig(
            predictedStaking, predictedSystemReward, predictedStakingPool, governance, predictedChainConfig, blend
        );
        chainConfig = ChainConfig(
            address(
                new ERC1967Proxy(
                    address(chainConfigImpl),
                    abi.encodeCall(
                        ChainConfig.initialize,
                        (
                            address(this),
                            uint32(3),
                            uint32(10),
                            uint32(150),
                            uint32(7),
                            uint32(1),
                            uint256(ONE),
                            uint256(ONE),
                            uint64(0),
                            address(0),
                            address(0),
                            uint256(0)
                        )
                    )
                )
            )
        );
        assertEq(address(staking), address(predictedStaking));
        assertEq(address(chainConfig), address(predictedChainConfig));

        vm.prank(validatorV);
        blend.approve(address(staking), type(uint256).max);
        blend.approve(address(staking), type(uint256).max);
    }

    function _rollToEpoch(uint64 epoch) internal {
        vm.roll(uint256(epoch) * chainConfig.getEpochBlockInterval());
    }

    /// @dev Build a two-op self-delegation queue [{epoch:1, 100}, {epoch:7, 200}] for validatorV (its own
    ///      owner self-delegation). registerValidator seeds the owner op at sinceEpoch = nextEpoch = 1; a
    ///      second delegate at epoch 5 appends an op at epoch 7 (warmup +2). validatorV is the sole
    ///      delegator, so the
    ///      per-epoch reward split denominator == the op amount → the owner receives the full injected reward.
    function _seedTwoOpQueue() internal {
        vm.prank(validatorV);
        staking.registerValidator(validatorV, 0, 100 * ONE); // owner op {epoch:1, amount:100}
        _rollToEpoch(5);
        vm.prank(validatorV);
        staking.delegate(validatorV, 100 * ONE); // appends owner op {epoch:7, amount:200}
    }

    /// T1: forfeiture across a bounded claim. Inject reward inside the [B, E2) gap; chunked claims must
    /// recover it. Pre-fix the second claim pays 0 (op1 was deleted at B, gap jumped to op2 at epoch 7).
    function test_forfeiture_recoveredAcrossBoundedClaim() public {
        _seedTwoOpQueue();

        // Rewards: one before the first claim bound (epoch 3), two inside the stranded gap [5, 7).
        staking.injectRewardAtEpoch(validatorV, 10 * ONE, 3); // paid by claim #1 (B=5)
        staking.injectRewardAtEpoch(validatorV, 50 * ONE, 5); // stranded pre-fix
        staking.injectRewardAtEpoch(validatorV, 40 * ONE, 6); // stranded pre-fix

        // Claim #1 with bound B = 5 (< next op epoch 7). Inner loop stops at B; op1 must be PRESERVED@5.
        uint256 before1 = blend.balanceOf(validatorV);
        vm.prank(validatorV);
        staking.claimDelegatorFeeAtEpoch(validatorV, 5);
        uint256 gain1 = blend.balanceOf(validatorV) - before1;
        assertEq(gain1, 10 * ONE, "claim #1 pays only the pre-bound epoch-3 reward");

        // Claim #2 with bound B = 7. Post-fix op1@5 is still present → accrues epochs 5,6 (90) then stops
        // at E2=7 and advances to op2. Pre-fix op1 was gone → this pays 0 and the 90 is lost forever.
        _rollToEpoch(7);
        uint256 before2 = blend.balanceOf(validatorV);
        vm.prank(validatorV);
        staking.claimDelegatorFeeAtEpoch(validatorV, 7);
        uint256 gain2 = blend.balanceOf(validatorV) - before2;
        assertEq(gain2, 90 * ONE, "claim #2 recovers the previously-stranded [5,7) reward (pre-fix: 0)");

        assertEq(gain1 + gain2, 100 * ONE, "full [1,7) reward integral recovered, nothing forfeited");
    }

    /// T2: the 1000-epoch cap amplifier. op2 sits 2000 epochs after op1; the cap forces B < E2 on the first
    /// claim, so a reward inside the [cap, E2) gap is stranded pre-fix. Chunked claims recover it post-fix.
    function test_forfeiture_capAmplifierGap() public {
        vm.prank(validatorV);
        staking.registerValidator(validatorV, 0, 100 * ONE); // op {epoch:1, 100}
        _rollToEpoch(1998);
        vm.prank(validatorV);
        staking.delegate(validatorV, 100 * ONE); // appends op {epoch:2000, 200}

        // Reward at epoch 1500 lands inside the [op1.epoch + 1000 = 1001, E2 = 2000) gap that the cap strands.
        staking.injectRewardAtEpoch(validatorV, 77 * ONE, 1500);

        _rollToEpoch(3000);
        uint256 before = blend.balanceOf(validatorV);
        // Drain in <=1000-epoch chunks until the pending fee is exhausted (repeat claims are the design).
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(validatorV);
            staking.claimDelegatorFeeAtEpoch(validatorV, 3000);
            if (staking.getPendingDelegatorFee(validatorV, validatorV) == 0) break;
        }
        uint256 gain = blend.balanceOf(validatorV) - before;
        assertEq(gain, 77 * ONE, "epoch-1500 reward in the cap gap is recovered, not stranded");
        assertEq(staking.getPendingDelegatorFee(validatorV, validatorV), 0, "queue fully drained");
    }

    /// T3 (control): when the inner loop stops at E2 (op fully consumed), the op MUST still be deleted and
    /// the cursor advanced. Guards against the fix over-preserving. A repeated same-bound claim pays 0.
    function test_control_stoppedAtE2_deletesAndAdvances() public {
        vm.prank(validatorV);
        staking.registerValidator(validatorV, 0, 100 * ONE); // op {epoch:1, 100}
        _rollToEpoch(2);
        vm.prank(validatorV);
        staking.delegate(validatorV, 100 * ONE); // appends op {epoch:4, 200}

        staking.injectRewardAtEpoch(validatorV, 10 * ONE, 2); // in op1 range [1,4)
        staking.injectRewardAtEpoch(validatorV, 10 * ONE, 4); // in op2 range [4,5)

        _rollToEpoch(5);
        uint256 before = blend.balanceOf(validatorV);
        vm.prank(validatorV);
        staking.claimDelegatorFeeAtEpoch(validatorV, 5); // spans past E2=4 → op1 consumed at E2, deleted
        uint256 gain = blend.balanceOf(validatorV) - before;
        assertEq(gain, 20 * ONE, "both op ranges paid in one claim");

        // Idempotency: op1 was deleted (not over-preserved), so a repeat claim to the same bound pays 0.
        uint256 before2 = blend.balanceOf(validatorV);
        vm.prank(validatorV);
        staking.claimDelegatorFeeAtEpoch(validatorV, 5);
        assertEq(blend.balanceOf(validatorV) - before2, 0, "no double-count: op consumed at E2 was deleted");
    }

    /// T4: view == claim in aggregate after the fix. getDelegatorFee reports the FULL pending integral;
    /// the sum of the chunked claim transfers must equal it exactly.
    function test_viewEqualsClaimAggregate() public {
        _seedTwoOpQueue();
        staking.injectRewardAtEpoch(validatorV, 10 * ONE, 3);
        staking.injectRewardAtEpoch(validatorV, 50 * ONE, 5);
        staking.injectRewardAtEpoch(validatorV, 40 * ONE, 6);

        _rollToEpoch(7);
        uint256 viewTotal = staking.getDelegatorFee(validatorV, validatorV); // current epoch = 7
        assertEq(viewTotal, 100 * ONE, "view reports the full [1,7) integral");

        uint256 before = blend.balanceOf(validatorV);
        vm.prank(validatorV);
        staking.claimDelegatorFeeAtEpoch(validatorV, 5);
        vm.prank(validatorV);
        staking.claimDelegatorFeeAtEpoch(validatorV, 7);
        uint256 claimed = blend.balanceOf(validatorV) - before;

        assertEq(claimed, viewTotal, "chunked claim total == view total (no forfeiture divergence)");
    }

    /// T5: same gap under ClaimMode.Redelegate. The reopened BLEND leg must restake the un-stranded amount;
    /// after chunked redelegate claims the pending fee is fully drained (nothing forfeited).
    function test_forfeiture_recoveredUnderRedelegate() public {
        _seedTwoOpQueue();
        staking.injectRewardAtEpoch(validatorV, 50 * ONE, 5);
        staking.injectRewardAtEpoch(validatorV, 40 * ONE, 6);

        // First redelegate at bound = current epoch 5: preserves op1@5 (gap reward not yet accrued).
        vm.prank(validatorV);
        staking.redelegateDelegatorFee(validatorV);

        _rollToEpoch(7);
        // Second redelegate accrues the [5,7) gap; pre-fix it would have been lost.
        vm.prank(validatorV);
        staking.redelegateDelegatorFee(validatorV);

        assertEq(
            staking.getPendingDelegatorFee(validatorV, validatorV),
            0,
            "redelegate path drains the gap reward too (no forfeiture)"
        );
    }

    function _singleton(address value) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _singleton16(uint16 value) internal pure returns (uint16[] memory values) {
        values = new uint16[](1);
        values[0] = value;
    }
}
