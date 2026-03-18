// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {FluentBridge} from "../../contracts/bridge/FluentBridge.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @notice Upgrades a FluentBridge (UUPS) proxy to the current implementation.
/// @dev Env: BRIDGE_PROXY (address), ALLOW_UNSAFE_UPGRADES=true. Uses UnsafeUpgrades
///      without validation, so the explicit env flag is required for operator safety.
contract UpgradeFluentBridge is Script {
    function run() external {
        address proxy = vm.envAddress("BRIDGE_PROXY");
        require(vm.envOr("ALLOW_UNSAFE_UPGRADES", false), "ALLOW_UNSAFE_UPGRADES=true required");

        vm.startBroadcast();
        FluentBridge newImpl = new FluentBridge();
        UnsafeUpgrades.upgradeProxy(proxy, address(newImpl), "");
        vm.stopBroadcast();
    }
}
