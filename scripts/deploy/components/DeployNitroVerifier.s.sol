// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {NitroVerifier} from "../../../contracts/verifier/NitroVerifier.sol";

/**
 * @notice Deploys NitroVerifier (non-upgradeable, plain constructor).
 * @dev Environment:
 * - ATTESTATION_VERIFIER (address, required): SP1 verifier contract
 * - ADMIN (address, required): DEFAULT_ADMIN_ROLE recipient
 * - OUTPUT_PATH (string, optional)
 */
contract DeployNitroVerifier is Script {
    function run() external returns (address verifier) {
        address attestationVerifier = vm.envAddress("ATTESTATION_VERIFIER");
        address admin = vm.envAddress("ADMIN");
        require(attestationVerifier != address(0), "ATTESTATION_VERIFIER is zero");
        require(admin != address(0), "ADMIN is zero");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        vm.startBroadcast();
        verifier = address(new NitroVerifier(attestationVerifier, admin));
        vm.stopBroadcast();

        console2.log("NitroVerifier deployed at", verifier);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "nitro_verifier", verifier);
            vm.writeJson(out, outputPath);
        }
    }
}
