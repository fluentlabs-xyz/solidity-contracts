// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @notice Upgrades Rollup proxy to the latest implementation.
/// @dev Env: PROXY_ADDRESS (required). Uses safe Upgrades API with storage layout validation.
contract UpgradeRollup is Script {
    function run() external {
        address proxy = vm.envAddress("PROXY_ADDRESS");
        require(proxy.code.length > 0, "proxy has no code");

        Options memory opts;
        opts.unsafeSkipStorageCheck = vm.envOr("UNSAFE_SKIP_STORAGE_CHECK", true);

        vm.startBroadcast();
        Upgrades.upgradeProxy(proxy, "Rollup.sol:Rollup", "", opts);
        vm.stopBroadcast();

        console2.log("Upgraded", proxy, "->", Upgrades.getImplementationAddress(proxy));
    }
}
