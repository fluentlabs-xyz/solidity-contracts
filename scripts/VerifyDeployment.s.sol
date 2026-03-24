// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, stdJson, console2} from "forge-std/Script.sol";

/// @notice Verifies that a deployment manifest matches on-chain state.
/// @dev Reads a deployment JSON and checks that every address has code deployed.
///      Run against the target chain RPC. Non-zero exit on any mismatch.
/// Environment:
/// - MANIFEST_PATH (string, required): path to deployment JSON
contract VerifyDeployment is Script {
    using stdJson for string;

    function run() external view {
        string memory path = vm.envString("MANIFEST_PATH");
        string memory json = vm.readFile(path);

        string[8] memory keys = [
            "bridge", "bridge_impl", "factory", "factory_impl",
            "gateway", "gateway_impl", "pegged_impl", "factory_beacon"
        ];

        uint256 checked;
        uint256 failed;

        for (uint256 i = 0; i < keys.length; i++) {
            string memory nested = string.concat(".deployment.", keys[i]);
            if (!vm.keyExistsJson(json, nested)) continue;
            address addr = json.readAddress(nested);
            if (addr == address(0)) continue;

            checked++;
            if (addr.code.length == 0) {
                console2.log("FAIL: no code at", keys[i], addr);
                failed++;
            } else {
                console2.log("OK:", keys[i], addr);
            }
        }

        console2.log("Checked:", checked, "Failed:", failed);
        require(failed == 0, "Deployment verification failed");
    }
}
