// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Staking} from "../../contracts/staking/Staking.sol";
import {MockStakingRewardInjector} from "../../contracts/staking/mocks/MockStakingRewardInjector.sol";
import {ChainConfig} from "../../contracts/staking/ChainConfig.sol";
import {MockBlendToken} from "../../contracts/staking/mocks/MockBlendToken.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {ISystemReward} from "../../contracts/staking/interfaces/ISystemReward.sol";
import {IStakingPool} from "../../contracts/staking/interfaces/IStakingPool.sol";
import {IFluentGovernance} from "../../contracts/staking/interfaces/IFluentGovernance.sol";
import {IChainConfig} from "../../contracts/staking/interfaces/IChainConfig.sol";

/// @notice Upgrade-migration smoke test: seeds validator/delegation/reward state, upgrades the proxy
///         to a fresh implementation, and asserts the ERC-7201 storage (`ValidatorSnapshot`,
///         `_jailedValidators`, the BLEND reward namespace) reads as expected across the upgrade.
contract StakingRewardUpgradeTest is Test {
    MockStakingRewardInjector internal staking;
    ChainConfig internal chainConfig;
    MockBlendToken internal blend;

    uint256 internal constant ONE = 1 ether;
    address internal validator1 = makeAddr("validator1");
    address internal staker1 = makeAddr("staker1");

    function setUp() public {
        blend = new MockBlendToken();
        blend.mint(address(this), 100 ether);
        blend.mint(staker1, 100 ether);

        uint64 nonce = vm.getNonce(address(this));
        // ChainConfig is deployed after MockStakingRewardInjector impl+proxy (nonce, nonce+1) and its
        // own impl (nonce+2), so its proxy lands at nonce+3.
        address predictedChainConfig = _create(address(this), nonce + 3);

        MockStakingRewardInjector sImpl = new MockStakingRewardInjector(
            IStaking(payable(address(0xdead))),
            ISystemReward(payable(address(0xdead))),
            IStakingPool(payable(address(0xdead))),
            IFluentGovernance(address(this)),
            IChainConfig(predictedChainConfig),
            blend,
            address(0),
            address(0)
        );
        staking = MockStakingRewardInjector(
            payable(address(
                    new ERC1967Proxy(
                        address(sImpl),
                        abi.encodeCall(
                            Staking.initialize, (address(this), new address[](0), new uint256[](0), uint16(0))
                        )
                    )
                ))
        );

        ChainConfig ccImpl = new ChainConfig(
            IStaking(payable(address(0xdead))),
            ISystemReward(payable(address(0xdead))),
            IStakingPool(payable(address(0xdead))),
            IFluentGovernance(address(this)),
            IChainConfig(predictedChainConfig),
            blend,
            0
        );
        chainConfig = ChainConfig(
            address(
                new ERC1967Proxy(
                    address(ccImpl),
                    abi.encodeCall(
                        ChainConfig.initialize,
                        (
                            address(this),
                            uint32(3),
                            uint32(100),
                            uint32(1),
                            uint32(1),
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
        require(address(chainConfig) == predictedChainConfig, "chain config prediction mismatch");

        blend.approve(address(staking), type(uint256).max);
        vm.prank(staker1);
        blend.approve(address(staking), type(uint256).max);
    }

    function _create(address deployer, uint64 nonce) internal pure returns (address) {
        require(nonce < 0x80, "nonce too high");
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(uint8(nonce))))))
        );
    }

    function test_stateSurvivesUpgradeAndNewSlotsRead() public {
        // Seed: validator + delegation + BLEND reward.
        staking.addValidator(validator1);
        vm.prank(staker1);
        staking.delegate(validator1, 10 ether);
        _rollEpoch();
        _rollEpoch(); // warmup: delegation effective before the reward
        staking.injectReward(validator1, 5 ether); // Stream-1 BLEND reward
        _rollEpoch();

        // Pre-upgrade reads.
        (, uint8 statusBefore,,,,,,) = staking.getValidatorStatus(validator1);
        (uint256 delegatedBefore,) = staking.getValidatorDelegation(validator1, staker1);
        uint256 delegatorFeeBefore = staking.getDelegatorFee(validator1, staker1);
        assertEq(statusBefore, uint8(IStaking.ValidatorStatus.Active));
        assertEq(delegatedBefore, 10 ether);
        assertGt(delegatorFeeBefore, 0, "reward accrued before upgrade");

        // Upgrade to a fresh implementation (same deps ⇒ matching immutables).
        MockStakingRewardInjector newImpl = new MockStakingRewardInjector(
            IStaking(payable(address(0xdead))),
            ISystemReward(payable(address(0xdead))),
            IStakingPool(payable(address(0xdead))),
            IFluentGovernance(address(this)),
            IChainConfig(address(chainConfig)),
            blend,
            address(0),
            address(0)
        );
        staking.upgradeToAndCall(address(newImpl), "");

        // Post-upgrade: pre-existing storage unchanged.
        (, uint8 statusAfter,,,,,,) = staking.getValidatorStatus(validator1);
        (uint256 delegatedAfter,) = staking.getValidatorDelegation(validator1, staker1);
        uint256 delegatorFeeAfter = staking.getDelegatorFee(validator1, staker1);
        assertEq(statusAfter, statusBefore);
        assertEq(delegatedAfter, delegatedBefore);
        assertEq(delegatorFeeAfter, delegatorFeeBefore, "BLEND reward ledger preserved across upgrade");

        // The seeded BLEND reward is still claimable after the upgrade.
        uint256 stakerBefore = blend.balanceOf(staker1);
        vm.prank(staker1);
        staking.claimDelegatorFee(validator1);
        assertEq(blend.balanceOf(staker1) - stakerBefore, delegatorFeeAfter, "reward claimable post-upgrade");
    }

    function _rollEpoch() internal {
        vm.roll(block.number + 100);
    }
}
