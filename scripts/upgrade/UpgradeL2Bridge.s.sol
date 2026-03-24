// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";

/// @notice Upgrades L2FluentBridge proxy to the latest implementation.
/// @dev Uses UnsafeUpgrades for L2 compatibility (Fluent VM does not support
///      the UPGRADE_INTERFACE_VERSION check used by the safe Upgrades API).
///      Env: PROXY_ADDRESS (required), ALLOW_UNSAFE_UPGRADES=true (required).
contract UpgradeL2Bridge is Script {
    function run() external {
        address proxy = vm.envAddress("PROXY_ADDRESS");
        require(proxy.code.length > 0, "proxy has no code");
        require(vm.envOr("ALLOW_UNSAFE_UPGRADES", false), "ALLOW_UNSAFE_UPGRADES=true required");

        vm.startBroadcast();
        address newImpl = address(new L2FluentBridge());
        UnsafeUpgrades.upgradeProxy(proxy, newImpl, "");
        vm.stopBroadcast();

        console2.log("Upgraded", proxy, "->", newImpl);
    }
}
