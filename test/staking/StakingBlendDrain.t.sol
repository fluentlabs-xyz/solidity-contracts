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

/// @notice F8 regression lock for the F1 BLEND drain (Fix-A). Reproduces the triage timeline — a quiet
///         validator whose settled epoch E was never materialized, plus a net undelegate in E+1/E+2 that
///         advances `changedAt` past E — and asserts the per-delegator claim denominator equals the TRUE
///         at-E stake (200), not the forward-copied `changedAt` value (100). Pre-Fix-A the credit
///         materialized snapshot[E] from `changedAt` ⇒ denominator 100 ⇒ owner+delegator each over-claim
///         200 for a 200 credit (drain 200 / over-claim revert). Post-Fix-A they split 200 exactly.
contract StakingBlendDrainTest is Test {
    uint256 internal constant ONE = 1 ether;

    MockStakingRewardInjector internal staking;
    ChainConfig internal chainConfig;
    MockBlendToken internal blend;

    address internal validatorV = makeAddr("validatorV");
    address internal delegatorB = makeAddr("delegatorB");

    function setUp() public {
        blend = new MockBlendToken();
        blend.mint(address(this), 1_000_000 ether);
        blend.mint(validatorV, 1_000_000 ether);
        blend.mint(delegatorB, 1_000_000 ether);

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
            payable(address(
                    new ERC1967Proxy(
                        address(stakingImpl),
                        abi.encodeCall(
                            Staking.initialize, (address(this), new address[](0), new uint256[](0), uint16(0))
                        )
                    )
                ))
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
            predictedStaking, predictedSystemReward, predictedStakingPool, governance, predictedChainConfig, blend, 0
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
                            address(0)
                        )
                    )
                )
            )
        );
        assertEq(address(staking), address(predictedStaking));
        assertEq(address(chainConfig), address(predictedChainConfig));

        vm.prank(validatorV);
        blend.approve(address(staking), type(uint256).max);
        vm.prank(delegatorB);
        blend.approve(address(staking), type(uint256).max);
        blend.approve(address(staking), type(uint256).max);
    }

    function _rollToEpoch(uint64 epoch) internal {
        vm.roll(uint256(epoch) * chainConfig.getEpochBlockInterval());
    }

    /// Reproduce the drain: quiet validator V (self-stake 100) + delegator B (100), true total 200 at
    /// epoch 6; B undelegates at epoch 7 (advancing changedAt to 8); reward 200 credited at E=6; owner
    /// and B each claim. Post-Fix-A: denominator == 200, total reward paid == 200 (conservation).
    function test_settleEpochStipendDoesNotDrainOnPastEpochCredit() public {
        // epoch 0: V registers with 100 self-stake (effective epoch 1), B delegates 100 (effective epoch 2).
        vm.prank(validatorV);
        staking.registerValidator(validatorV, 0, 100 * ONE);
        vm.prank(delegatorB);
        staking.delegate(validatorV, 100 * ONE);

        // Advance to epoch 7 with both effective (true total delegated = 200). B undelegates all 100 at
        // epoch 7 ⇒ touch(nextEpoch=8) ⇒ changedAt advances to 8 (> the E=6 that will be credited).
        _rollToEpoch(7);
        vm.prank(delegatorB);
        staking.undelegate(validatorV, 100 * ONE);

        // epoch 8 = current. Credit a 200 BLEND stipend at E = current - 2 = 6 (unmaterialized, changedAt=8).
        _rollToEpoch(8);
        staking.injectRewardAtEpoch(validatorV, 200 * ONE, 6);

        // The materialized epoch-6 denominator must be the TRUE at-6 stake (200), not the forward-copied
        // changedAt=8 value (100 after B's undelegate). This is the drain root.
        assertEq(staking.snapshotTotalDelegated(validatorV, 6), 200 * ONE, "snapshot[6] must be the true at-E total");

        uint256 contractBefore = blend.balanceOf(address(staking));
        uint256 vBefore = blend.balanceOf(validatorV);
        uint256 bBefore = blend.balanceOf(delegatorB);

        // Owner V (self-delegation) + delegator B each claim. Pre-fix the second claim over-claims / reverts.
        vm.prank(validatorV);
        staking.claimDelegatorFee(validatorV);
        vm.prank(delegatorB);
        staking.claimDelegatorFee(validatorV);

        // B's undelegation matures at epoch 7 + undelegatePeriod(7) = 14, so at epoch 8 both claims pay
        // reward ONLY; the two 100 principals stay in the contract.
        uint256 vGain = blend.balanceOf(validatorV) - vBefore;
        uint256 bGain = blend.balanceOf(delegatorB) - bBefore;

        // Commission 0, denominator 200, each 100-stake share ⇒ 100 reward apiece. Total reward paid == 200
        // (the exact credit). Pre-Fix-A the denominator was 100 ⇒ each claimed 200 ⇒ 400 paid, draining
        // the two 100 principals to zero.
        assertEq(vGain, 100 * ONE, "owner reward == credited share");
        assertEq(bGain, 100 * ONE, "delegator reward == credited share");
        assertEq(vGain + bGain, 200 * ONE, "total reward paid == credited (conservation, not 400)");

        // Contract retains both 100 principals (owner live + B unbonding); pre-fix it would be drained to 0.
        assertEq(blend.balanceOf(address(staking)), contractBefore - 200 * ONE, "only the 200 reward left");
        assertEq(blend.balanceOf(address(staking)), 200 * ONE, "both principals intact (no drain)");
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
