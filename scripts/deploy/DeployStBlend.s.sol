// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {stBlend} from "../../contracts/stBlend/stBlend.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys {stBlend} behind a UUPS proxy.
/// @dev Inherit and call _deployStBlend(...) inside your broadcast.
contract DeployStBlend is DeployBase {
    struct StBlendParams {
        address asset;
        string name;
        string symbol;
        address admin;
        address pauser;
        address rewardsDistributor;
        uint64 streamDuration;
        uint256 maxTotalAssets;
    }

    struct StBlendResult {
        address vault;
        address vaultImpl;
    }

    function _deployStBlend(StBlendParams memory p) internal returns (StBlendResult memory r) {
        r.vault = Upgrades.deployUUPSProxy(
            "stBlend.sol:stBlend",
            abi.encodeCall(
                stBlend.initialize,
                (
                    IERC20(p.asset),
                    p.name,
                    p.symbol,
                    p.admin,
                    p.pauser,
                    p.rewardsDistributor,
                    p.streamDuration,
                    p.maxTotalAssets
                )
            )
        );
        r.vaultImpl = Upgrades.getImplementationAddress(r.vault);
    }

    /// @dev Standalone entry. Required env vars:
    ///        ASSET_ADDRESS, NAME, SYMBOL, ADMIN, PAUSER, REWARDS_DISTRIBUTOR,
    ///        STREAM_DURATION, MAX_TOTAL_ASSETS
    ///      Optional: OUTPUT_PATH (JSON manifest output).
    function run() external virtual {
        StBlendParams memory p = StBlendParams({
            asset: vm.envAddress("ASSET_ADDRESS"),
            name: vm.envString("NAME"),
            symbol: vm.envString("SYMBOL"),
            admin: vm.envAddress("ADMIN"),
            pauser: vm.envAddress("PAUSER"),
            rewardsDistributor: vm.envAddress("REWARDS_DISTRIBUTOR"),
            streamDuration: uint64(vm.envUint("STREAM_DURATION")),
            maxTotalAssets: vm.envUint("MAX_TOTAL_ASSETS")
        });
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying stBlend");
        console2.log("  asset:", p.asset);
        console2.log("  name:", p.name);
        console2.log("  symbol:", p.symbol);
        console2.log("  admin:", p.admin);
        console2.log("  pauser:", p.pauser);
        console2.log("  rewardsDistributor:", p.rewardsDistributor);
        console2.log("  streamDuration:", p.streamDuration);
        console2.log("  maxTotalAssets:", p.maxTotalAssets);

        vm.startBroadcast();
        StBlendResult memory r = _deployStBlend(p);
        vm.stopBroadcast();

        console2.log("stBlend deployed:", r.vault);
        console2.log("  impl:", r.vaultImpl);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "stBlend", r.vault);
            out = vm.serializeAddress("deployment", "stBlend_impl", r.vaultImpl);
            vm.writeJson(out, outputPath);
        }
    }
}
