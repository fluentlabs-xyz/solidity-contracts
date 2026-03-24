// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {L1BlockOracle} from "../../../contracts/oracles/L1BlockOracle.sol";

/**
 * @notice Deploys L1BlockOracle (non-upgradeable, plain constructor).
 * @dev Environment:
 * - SUBMITTER (address, required): hot key for block number updates
 * - OUTPUT_PATH (string, optional)
 */
contract DeployL1BlockOracle is Script {
    function run() external returns (address oracle) {
        address submitter = vm.envAddress("SUBMITTER");
        require(submitter != address(0), "SUBMITTER is zero");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        vm.startBroadcast();
        oracle = address(new L1BlockOracle(submitter));
        vm.stopBroadcast();

        console2.log("L1BlockOracle deployed at", oracle);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "l1_block_oracle", oracle);
            vm.writeJson(out, outputPath);
        }
    }
}
