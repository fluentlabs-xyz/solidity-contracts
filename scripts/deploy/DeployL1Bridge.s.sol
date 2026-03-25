// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {FluentBridgeStorageLayout} from "../../contracts/bridge/FluentBridgeStorageLayout.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys L1FluentBridge behind a UUPS proxy.
/// @dev Inherit and call _deployL1Bridge() inside your broadcast.
contract DeployL1Bridge is DeployBase {
    struct L1BridgeResult {
        address proxy;
        address impl;
    }

    function _deployL1Bridge(
        address adminRole,
        address pauserRole,
        address relayerRole,
        address otherBridge,
        address rollup
    ) internal returns (L1BridgeResult memory r) {
        FluentBridgeStorageLayout.InitConfiguration memory params = FluentBridgeStorageLayout.InitConfiguration({
            adminRole: adminRole,
            pauserRole: pauserRole,
            relayerRole: relayerRole,
            otherBridge: otherBridge
        });
        r.proxy = Upgrades.deployUUPSProxy(
            "L1FluentBridge.sol:L1FluentBridge",
            abi.encodeCall(L1FluentBridge.initialize, (abi.encode(params), rollup))
        );
        r.impl = Upgrades.getImplementationAddress(r.proxy);
    }

    /// @dev Standalone: ADMIN_ROLE, PAUSER_ROLE, RELAYER_ROLE, ROLLUP_ADDRESS required.
    function run() external virtual {
        address adminRole = vm.envAddress("ADMIN_ROLE");
        address pauserRole = vm.envAddress("PAUSER_ROLE");
        address relayerRole = vm.envAddress("RELAYER_ROLE");
        address otherBridge = vm.envOr("OTHER_BRIDGE", address(0x1));
        address rollup = vm.envAddress("ROLLUP_ADDRESS");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying L1FluentBridge");
        console2.log("  admin:", adminRole);
        console2.log("  rollup:", rollup);

        vm.startBroadcast();
        L1BridgeResult memory r = _deployL1Bridge(adminRole, pauserRole, relayerRole, otherBridge, rollup);
        vm.stopBroadcast();

        console2.log("L1FluentBridge deployed:", r.proxy);
        console2.log("  impl:", r.impl);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "bridge", r.proxy);
            out = vm.serializeAddress("deployment", "bridge_impl", r.impl);
            vm.writeJson(out, outputPath);
        }
    }
}
