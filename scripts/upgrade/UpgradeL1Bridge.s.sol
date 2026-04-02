// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";

/// @notice Upgrades L1FluentBridge proxy to the latest implementation.
/// @dev Env: PROXY_ADDRESS (required), REFERENCE_BUILD_INFO_DIR (required — path to previous build info).
contract UpgradeL1Bridge is Script {
    function run() external {
        address proxy = vm.envAddress("PROXY_ADDRESS");
        require(proxy.code.length > 0, "proxy has no code");

        Options memory opts;
        opts.referenceBuildInfoDir = vm.envString("REFERENCE_BUILD_INFO_DIR");

        vm.startBroadcast();
        Upgrades.upgradeProxy(proxy, "L1FluentBridge.sol:L1FluentBridge", "", opts);
        vm.stopBroadcast();

        console2.log("Upgraded", proxy, "->", Upgrades.getImplementationAddress(proxy));
    }
}
