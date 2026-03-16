// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {FluentBridge} from "../../contracts/FluentBridge.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @notice Upgrades a FluentBridge (UUPS) proxy to the current implementation.
/// @dev Env: BRIDGE_PROXY (address). Uses UnsafeUpgrades (no artifact lookup, no upgrade validations).
contract UpgradeFluentBridge is Script {
    function run() external {
        address proxy = vm.envAddress("BRIDGE_PROXY");

        vm.startBroadcast();
        FluentBridge newImpl = new FluentBridge();
        UnsafeUpgrades.upgradeProxy(proxy, address(newImpl), "");
        vm.stopBroadcast();
    }
}
