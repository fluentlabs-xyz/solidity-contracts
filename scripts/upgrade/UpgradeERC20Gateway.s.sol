// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @notice Upgrades ERC20Gateway proxy to the latest implementation.
/// @dev Env: PROXY_ADDRESS (required), UNSAFE_SKIP_STORAGE_CHECK (optional, for first upgrade without reference build).
contract UpgradeERC20Gateway is Script {
    function run() external {
        address proxy = vm.envAddress("PROXY_ADDRESS");
        require(proxy.code.length > 0, "proxy has no code");

        Options memory opts;
        opts.referenceContract = vm.envOr("REFERENCE_CONTRACT", string("ERC20Gateway.sol:ERC20Gateway"));
        opts.unsafeSkipStorageCheck = vm.envOr("UNSAFE_SKIP_STORAGE_CHECK", false);

        vm.startBroadcast();
        Upgrades.upgradeProxy(proxy, "ERC20Gateway.sol:ERC20Gateway", "", opts);
        vm.stopBroadcast();

        console2.log("Upgraded", proxy, "->", Upgrades.getImplementationAddress(proxy));
    }
}
