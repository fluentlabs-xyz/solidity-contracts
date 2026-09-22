// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {DrandOracle} from "../../contracts/oracles/DrandOracle.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys DrandOracle behind a UUPS proxy.
/// @dev Env: ADMIN_ROLE (DEFAULT_ADMIN_ROLE: upgrades; falls back to `.roles.admin` of the NETWORK
///      config, default testnet/l2), EMERGENCY_ROLE (pauses publishing; falls back to
///      `.roles.emergency` when the config names one, else the admin), OUTPUT_PATH (optional).
///      In production both roles move to the timelocks with MigrateRoles.
contract DeployDrandOracle is DeployBase {
    using stdJson for string;

    struct DrandOracleResult {
        address oracle;
        address oracleImpl;
    }

    function _deployDrandOracle(address admin, address emergency) internal returns (DrandOracleResult memory r) {
        r.oracle = Upgrades.deployUUPSProxy(
            "DrandOracle.sol:DrandOracle", abi.encodeCall(DrandOracle.initialize, (admin, emergency))
        );
        r.oracleImpl = Upgrades.getImplementationAddress(r.oracle);
    }

    function run() external virtual {
        string memory json = _readConfig(vm.envOr("NETWORK", string("testnet/l2")));
        address admin = vm.envOr("ADMIN_ROLE", json.readAddress(".roles.admin"));
        address emergency = vm.envOr("EMERGENCY_ROLE", _roleOr(json, ".roles.emergency", admin));
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying DrandOracle");
        console2.log("  admin:", admin);
        console2.log("  emergency:", emergency);

        vm.startBroadcast();
        DrandOracleResult memory r = _deployDrandOracle(admin, emergency);
        vm.stopBroadcast();

        console2.log("DrandOracle deployed:", r.oracle);
        console2.log("  impl:", r.oracleImpl);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "drand_oracle", r.oracle);
            out = vm.serializeAddress("deployment", "drand_oracle_impl", r.oracleImpl);
            vm.writeJson(out, outputPath);
        }
    }

    function _roleOr(string memory json, string memory key, address fallback_) internal view returns (address) {
        if (!vm.keyExistsJson(json, key)) return fallback_;
        address named = json.readAddress(key);
        return named == address(0) ? fallback_ : named;
    }
}
