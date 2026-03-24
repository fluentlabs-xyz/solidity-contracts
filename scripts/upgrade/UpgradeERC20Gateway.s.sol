// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @notice Upgrades ERC20Gateway proxy to the latest implementation.
/// @dev Env: PROXY_ADDRESS (required). Uses safe Upgrades API with storage layout validation.
contract UpgradeERC20Gateway is Script {
    function run() external {
        address proxy = vm.envAddress("PROXY_ADDRESS");
        require(proxy.code.length > 0, "proxy has no code");

        vm.startBroadcast();
        Upgrades.upgradeProxy(proxy, "ERC20Gateway.sol:ERC20Gateway", "");
        vm.stopBroadcast();

        console2.log("Upgraded", proxy, "->", Upgrades.getImplementationAddress(proxy));
    }
}
