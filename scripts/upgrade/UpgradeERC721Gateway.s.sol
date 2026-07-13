// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @notice Upgrades ERC721Gateway proxy to the latest implementation.
/// @dev Env: PROXY_ADDRESS (required), UNSAFE_SKIP_STORAGE_CHECK (optional, for first upgrade without reference build).
contract UpgradeERC721Gateway is Script {
    function run() external {
        address proxy = vm.envAddress("PROXY_ADDRESS");
        require(proxy.code.length > 0, "proxy has no code");

        Options memory opts;
        opts.referenceContract = vm.envOr("REFERENCE_CONTRACT", string("ERC721Gateway.sol:ERC721Gateway"));
        opts.unsafeSkipStorageCheck = vm.envOr("UNSAFE_SKIP_STORAGE_CHECK", true);

        vm.startBroadcast();
        Upgrades.upgradeProxy(proxy, "ERC721Gateway.sol:ERC721Gateway", "", opts);
        vm.stopBroadcast();

        console2.log("Upgraded", proxy, "->", Upgrades.getImplementationAddress(proxy));
    }
}
