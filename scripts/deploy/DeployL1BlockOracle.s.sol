// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {L1BlockOracle} from "../../contracts/oracles/L1BlockOracle.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys L1BlockOracle (plain contract, not upgradeable).
contract DeployL1BlockOracle is DeployBase {
    using stdJson for string;

    function _deployL1BlockOracle(address submitter) internal returns (address) {
        return address(new L1BlockOracle(submitter));
    }

    /// @dev Standalone: SUBMITTER required (or RELAYER_ROLE with NETWORK config fallback).
    function run() external virtual {
        string memory json = _readConfig(vm.envOr("NETWORK", string("testnet/l2")));
        address submitter = vm.envOr("SUBMITTER", json.readAddress(".roles.relayer"));
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying L1BlockOracle");
        console2.log("  submitter:", submitter);

        vm.startBroadcast();
        address oracle = _deployL1BlockOracle(submitter);
        vm.stopBroadcast();

        console2.log("L1BlockOracle deployed:", oracle);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "l1_block_oracle", oracle);
            vm.writeJson(out, outputPath);
        }
    }
}
