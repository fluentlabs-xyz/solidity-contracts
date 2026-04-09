// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {NitroVerifier} from "../../contracts/verifier/NitroVerifier.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys NitroVerifier (plain contract, not upgradeable).
contract DeployNitroVerifier is DeployBase {
    using stdJson for string;

    function _deployNitroVerifier(address sp1Verifier, address admin) internal returns (address) {
        return address(new NitroVerifier(sp1Verifier, admin));
    }

    /// @dev Standalone: SP1_VERIFIER, ADMIN_ROLE required. Or use NETWORK for config fallback.
    function run() external virtual {
        string memory json = _readConfig(vm.envOr("NETWORK", string("testnet/l1")));
        address sp1Verifier = vm.envOr("SP1_VERIFIER", json.readAddress(".rollup.sp1Verifier"));
        address adminRole = vm.envOr("ADMIN_ROLE", json.readAddress(".roles.admin"));
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying NitroVerifier");
        console2.log("  sp1Verifier:", sp1Verifier);
        console2.log("  admin:", adminRole);

        vm.startBroadcast();
        address nitroVerifier = _deployNitroVerifier(sp1Verifier, adminRole);
        vm.stopBroadcast();

        console2.log("NitroVerifier deployed:", nitroVerifier);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "nitro_verifier", nitroVerifier);
            vm.writeJson(out, outputPath);
        }
    }
}
