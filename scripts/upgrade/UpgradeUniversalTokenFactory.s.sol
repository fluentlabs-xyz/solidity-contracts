// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";

/// @notice Upgrades UniversalTokenFactory proxy to the latest implementation.
/// @dev Uses UnsafeUpgrades because UniversalTokenSDK library is unlinked.
///      Requires ALLOW_UNSAFE_UPGRADES=true.
contract UpgradeUniversalTokenFactory is Script {
    function run() external {
        address proxy = vm.envAddress("PROXY_ADDRESS");
        require(proxy.code.length > 0, "proxy has no code");
        require(vm.envOr("ALLOW_UNSAFE_UPGRADES", false), "ALLOW_UNSAFE_UPGRADES=true required");

        vm.startBroadcast();
        UniversalTokenFactory newImpl = new UniversalTokenFactory();
        UnsafeUpgrades.upgradeProxy(proxy, address(newImpl), "");
        vm.stopBroadcast();

        console2.log("Upgraded", proxy, "->", address(newImpl));
    }
}
