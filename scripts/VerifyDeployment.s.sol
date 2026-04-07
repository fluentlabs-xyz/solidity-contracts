// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson, console2} from "forge-std/Script.sol";
import {DeployBase} from "./deploy/DeployBase.s.sol";

/// @notice Verifies that a deployment manifest matches on-chain state.
/// @dev Reads a deployment JSON and checks that every address has code deployed.
///      Run against the target chain RPC. Non-zero exit on any mismatch.
///
/// Environment:
/// - ENV (default: testnet) + LAYER (required: l1 or l2) — determines manifest path
/// - Or MANIFEST_PATH (overrides ENV/LAYER)
contract VerifyDeployment is DeployBase {
    using stdJson for string;

    function run() external view {
        string memory path = _manifestPath();
        string memory json = vm.readFile(path);
        console2.log("Verifying manifest:", path);

        // All possible keys across L1 and L2 manifests
        string[16] memory keys = [
            "bridge",
            "bridge_impl",
            "rollup",
            "rollup_impl",
            "nitro_verifier",
            "factory",
            "factory_impl",
            "factory_beacon",
            "pegged_impl",
            "erc20_gateway",
            "erc20_gateway_impl",
            "native_gateway",
            "native_gateway_impl",
            "l1_block_oracle",
            "l1_gas_oracle",
            "mock_token"
        ];

        uint256 checked;
        uint256 failed;
        uint256 skipped;

        for (uint256 i = 0; i < keys.length; i++) {
            address addr = _readAddr(json, keys[i]);
            if (addr == address(0)) {
                skipped++;
                continue;
            }

            checked++;
            if (addr.code.length == 0) {
                console2.log("  FAIL:", keys[i], addr);
                failed++;
            } else {
                console2.log("  OK:  ", keys[i], addr);
            }
        }

        console2.log("");
        console2.log("Checked:", checked);
        console2.log("Failed:", failed);
        console2.log("Skipped:", skipped);
        require(failed == 0, "Deployment verification failed");
    }

    function _manifestPath() internal view returns (string memory) {
        string memory override_ = vm.envOr("MANIFEST_PATH", string(""));
        if (bytes(override_).length > 0) return override_;

        string memory env = vm.envOr("ENV", string("testnet"));
        string memory layer = vm.envString("LAYER");
        return string.concat("deployments/", env, "/", layer, ".json");
    }

}
