// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {DrandOracle} from "../../contracts/oracles/DrandOracle.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys DrandOracle (plain contract, not upgradeable).
contract DeployDrandOracle is DeployBase {
    using stdJson for string;

    function _deployDrandOracle(address initialOwner) internal returns (address) {
        return address(new DrandOracle(initialOwner));
    }

    /// @dev Standalone: INITIAL_OWNER required (or NETWORK config fallback).
    function run() external virtual {
        string memory json = _readConfig(vm.envOr("NETWORK", string("testnet/l2")));
        address initialOwner = vm.envOr("INITIAL_OWNER", json.readAddress(".roles.initialOwner"));
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying DrandOracle");
        console2.log("  initialOwner:", initialOwner);

        vm.startBroadcast();
        address oracle = _deployDrandOracle(initialOwner);
        vm.stopBroadcast();

        console2.log("DrandOracle deployed:", oracle);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "drand_oracle", oracle);
            vm.writeJson(out, outputPath);
        }
    }
}
