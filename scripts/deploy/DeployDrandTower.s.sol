// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {DrandTower} from "../../contracts/examples/DrandTower.sol";
import {DeployBase} from "./DeployBase.s.sol";

/**
 * @notice Deploys DrandTower, the reference consumer, against an already-deployed DrandOracle.
 * @dev Env: DRAND_ORACLE (required unless MANIFEST names one), MANIFEST (a deployment JSON to
 *      read `drand_oracle` from, default `deployments/testnet/drand.json`), OUTPUT_PATH
 *      (optional; both addresses are written, since `vm.writeJson` replaces the whole file).
 */
contract DeployDrandTower is DeployBase {
    using stdJson for string;

    function run() external {
        string memory manifestPath = vm.envOr("MANIFEST", string("deployments/testnet/drand.json"));
        address oracle = vm.envOr("DRAND_ORACLE", _oracleFrom(manifestPath));
        require(oracle != address(0), "no oracle: set DRAND_ORACLE or point MANIFEST at one");
        require(oracle.code.length > 0, "oracle address has no code");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying DrandTower");
        console2.log("  oracle:", oracle);

        vm.startBroadcast();
        DrandTower tower = new DrandTower(oracle);
        vm.stopBroadcast();

        console2.log("DrandTower deployed:", address(tower));
        // Read back through the game so a deployment that cannot see its oracle fails here
        // rather than on a player's first climb.
        console2.log("  oracle currentRound():", tower.ORACLE().currentRound());

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "drand_oracle", oracle);
            out = vm.serializeAddress("deployment", "drand_tower", address(tower));
            vm.writeJson(out, outputPath);
        }
    }

    /// @dev The oracle recorded by an earlier deployment, or zero when there is no manifest.
    function _oracleFrom(string memory path) internal view returns (address) {
        if (!vm.exists(path)) return address(0);
        return _readAddr(vm.readFile(path), "drand_oracle");
    }
}
