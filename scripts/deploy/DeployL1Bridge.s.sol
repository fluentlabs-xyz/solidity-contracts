// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {FluentBridgeStorageLayout} from "../../contracts/bridge/FluentBridgeStorageLayout.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys L1FluentBridge behind a UUPS proxy.
/// @dev Inherit and call _deployL1Bridge() inside your broadcast.
contract DeployL1Bridge is DeployBase {
    using stdJson for string;

    struct L1BridgeResult {
        address proxy;
        address impl;
    }

    function _deployL1Bridge(
        address adminRole,
        address pauserRole,
        address relayerRole,
        address otherBridge,
        address rollup,
        uint256 receiveMessageDeadline,
        uint256 depositProcessingWindow
    ) internal returns (L1BridgeResult memory r) {
        FluentBridgeStorageLayout.InitConfiguration memory params = FluentBridgeStorageLayout.InitConfiguration({
            adminRole: adminRole,
            pauserRole: pauserRole,
            relayerRole: relayerRole,
            otherBridge: otherBridge
        });
        r.proxy = Upgrades.deployUUPSProxy(
            "L1FluentBridge.sol:L1FluentBridge",
            abi.encodeCall(
                L1FluentBridge.initialize,
                (abi.encode(params), rollup, receiveMessageDeadline, depositProcessingWindow)
            )
        );
        r.impl = Upgrades.getImplementationAddress(r.proxy);
    }

    /// @dev Standalone: ADMIN_ROLE, PAUSER_ROLE, RELAYER_ROLE, ROLLUP_ADDRESS required.
    ///      Reads RECEIVE_MSG_DEADLINE and DEPOSIT_PROCESSING_WINDOW from env or NETWORK config.
    function run() external virtual {
        string memory json = _readConfig(vm.envOr("NETWORK", string("testnet/l1")));
        address adminRole = vm.envAddress("ADMIN_ROLE");
        address pauserRole = vm.envAddress("PAUSER_ROLE");
        address relayerRole = vm.envAddress("RELAYER_ROLE");
        address otherBridge = vm.envOr("OTHER_BRIDGE", address(0x1));
        address rollup = vm.envAddress("ROLLUP_ADDRESS");
        uint256 receiveMessageDeadline = vm.envOr("RECEIVE_MSG_DEADLINE", json.readUint(".bridge.receiveMessageDeadline"));
        uint256 depositProcessingWindow = vm.envOr("DEPOSIT_PROCESSING_WINDOW", json.readUint(".bridge.depositProcessingWindow"));
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying L1FluentBridge");
        console2.log("  admin:", adminRole);
        console2.log("  rollup:", rollup);
        console2.log("  receiveMessageDeadline:", receiveMessageDeadline);
        console2.log("  depositProcessingWindow:", depositProcessingWindow);

        vm.startBroadcast();
        L1BridgeResult memory r = _deployL1Bridge(
            adminRole,
            pauserRole,
            relayerRole,
            otherBridge,
            rollup,
            receiveMessageDeadline,
            depositProcessingWindow
        );
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
