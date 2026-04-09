// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {FluentBridgeStorageLayout} from "../../contracts/bridge/FluentBridgeStorageLayout.sol";
import {L1GasOracle} from "../../contracts/oracles/L1GasOracle.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys L2FluentBridge behind a UUPS proxy.
/// @dev Inherit and call _deployL2Bridge() inside your broadcast.
///      Gas oracle must be deployed separately and passed as a parameter.
contract DeployL2Bridge is DeployBase {
    using stdJson for string;

    struct L2BridgeResult {
        address proxy;
        address impl;
    }

    function _deployL2Bridge(
        address adminRole,
        address pauserRole,
        address relayerRole,
        address otherBridge,
        address l1BlockOracle,
        address gasOracle,
        address feeTreasury
    ) internal returns (L2BridgeResult memory r) {
        require(l1BlockOracle != address(0), "L1_BLOCK_ORACLE required");
        require(gasOracle != address(0), "l1_gas_oracle required");
        address treasury = feeTreasury == address(0) ? adminRole : feeTreasury;
        FluentBridgeStorageLayout.InitConfiguration memory params = FluentBridgeStorageLayout.InitConfiguration({
            adminRole: adminRole,
            pauserRole: pauserRole,
            relayerRole: relayerRole,
            otherBridge: otherBridge
        });
        r.proxy = Upgrades.deployUUPSProxy(
            "L2FluentBridge.sol:L2FluentBridge",
            abi.encodeCall(L2FluentBridge.initialize, (abi.encode(params), l1BlockOracle, gasOracle, 0, 0, 0, treasury))
        );
        r.impl = Upgrades.getImplementationAddress(r.proxy);
    }

    /// @dev Standalone: NETWORK, L1_BLOCK_ORACLE required. Reads roles from config.
    ///      Deploys L1GasOracle inline, then passes to _deployL2Bridge.
    function run() external virtual {
        string memory json = _readConfig(vm.envOr("NETWORK", string("testnet/l2")));
        address adminRole = vm.envOr("ADMIN_ROLE", json.readAddress(".roles.admin"));
        address pauserRole = vm.envOr("PAUSER_ROLE", json.readAddress(".roles.pauser"));
        address relayerRole = vm.envOr("RELAYER_ROLE", json.readAddress(".roles.relayer"));
        address otherBridge = vm.envOr("OTHER_BRIDGE", address(0x1));
        address l1BlockOracle = vm.envAddress("L1_BLOCK_ORACLE");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying L2FluentBridge");
        console2.log("  admin:", adminRole);
        console2.log("  l1BlockOracle:", l1BlockOracle);

        vm.startBroadcast();
        address gasOracle = address(new L1GasOracle(relayerRole));
        L2BridgeResult memory r = _deployL2Bridge(
            adminRole,
            pauserRole,
            relayerRole,
            otherBridge,
            l1BlockOracle,
            gasOracle,
            address(0)
        );
        vm.stopBroadcast();

        console2.log("L2FluentBridge deployed:", r.proxy);
        console2.log("  impl:", r.impl);
        console2.log("  gasOracle:", gasOracle);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "bridge", r.proxy);
            out = vm.serializeAddress("deployment", "bridge_impl", r.impl);
            out = vm.serializeAddress("deployment", "l1_gas_oracle", gasOracle);
            vm.writeJson(out, outputPath);
        }
    }
}
