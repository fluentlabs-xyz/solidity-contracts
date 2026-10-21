// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {IstBlend} from "../../contracts/interfaces/IstBlend.sol";
import {RewardPool} from "../../contracts/stBlend/RewardPool.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys {RewardPool} behind a UUPS proxy.
/// @dev Deploy after {stBlend}. Grant {REWARDS_DISTRIBUTOR_ROLE} on the vault to the pool
///      proxy address before the first {distribute} call.
contract DeployRewardPool is DeployBase {
    struct RewardPoolParams {
        address admin;
        address vault;
        uint256 dailyRewardAmount;
        uint64 distributionPeriod;
    }

    struct RewardPoolResult {
        address pool;
        address poolImpl;
    }

    function _deployRewardPool(RewardPoolParams memory p) internal returns (RewardPoolResult memory r) {
        r.pool = Upgrades.deployUUPSProxy(
            "RewardPool.sol:RewardPool",
            abi.encodeCall(
                RewardPool.initialize,
                (p.admin, IstBlend(p.vault), p.dailyRewardAmount, p.distributionPeriod)
            )
        );
        r.poolImpl = Upgrades.getImplementationAddress(r.pool);
    }

    /// @dev Standalone entry. Required env vars:
    ///        ADMIN, VAULT_ADDRESS, DAILY_REWARD_AMOUNT, DISTRIBUTION_PERIOD
    ///      Optional: OUTPUT_PATH (JSON manifest output).
    function run() external virtual {
        RewardPoolParams memory p = RewardPoolParams({
            admin: vm.envAddress("ADMIN"),
            vault: vm.envAddress("VAULT_ADDRESS"),
            dailyRewardAmount: vm.envUint("DAILY_REWARD_AMOUNT"),
            distributionPeriod: uint64(vm.envUint("DISTRIBUTION_PERIOD"))
        });
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying RewardPool");
        console2.log("  admin:", p.admin);
        console2.log("  vault:", p.vault);
        console2.log("  dailyRewardAmount:", p.dailyRewardAmount);
        console2.log("  distributionPeriod:", p.distributionPeriod);

        vm.startBroadcast();
        RewardPoolResult memory r = _deployRewardPool(p);
        vm.stopBroadcast();

        console2.log("RewardPool deployed:", r.pool);
        console2.log("  impl:", r.poolImpl);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "rewardPool", r.pool);
            out = vm.serializeAddress("deployment", "rewardPool_impl", r.poolImpl);
            vm.writeJson(out, outputPath);
        }
    }
}
