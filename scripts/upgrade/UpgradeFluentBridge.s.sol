// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @notice Upgrades a FluentBridge (UUPS) proxy to the current implementation.
/// @dev Env: BRIDGE_PROXY (address), BRIDGE_LAYER ("L1"|"L2"), ALLOW_UNSAFE_UPGRADES=true. Uses UnsafeUpgrades
///      without validation, so the explicit env flag is required for operator safety.
contract UpgradeFluentBridge is Script {
    function run() external {
        address proxy = vm.envAddress("BRIDGE_PROXY");
        require(vm.envOr("ALLOW_UNSAFE_UPGRADES", false), "ALLOW_UNSAFE_UPGRADES=true required");
        string memory layer = vm.envOr("BRIDGE_LAYER", string("L1"));

        vm.startBroadcast();
        address newImpl;
        if (keccak256(bytes(layer)) == keccak256(bytes("L2"))) {
            newImpl = address(new L2FluentBridge());
        } else {
            // default: L1
            newImpl = address(new L1FluentBridge());
        }
        UnsafeUpgrades.upgradeProxy(proxy, newImpl, "");
        vm.stopBroadcast();
    }
}
