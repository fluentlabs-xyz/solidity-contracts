// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @notice Upgrades L1FluentBridge proxy to the latest implementation.
/// @dev Env: PROXY_ADDRESS (required), REFERENCE_BUILD_INFO_DIR (optional — path to a previous
///      build-info directory for storage-layout comparison), REFERENCE_CONTRACT (optional —
///      defaults to the current build; when REFERENCE_BUILD_INFO_DIR is set, use the
///      `<dirShortName>:L1FluentBridge` format), UNSAFE_SKIP_STORAGE_CHECK (optional, for first
///      upgrade without a reference build).
contract UpgradeL1Bridge is Script {
    function run() external {
        address proxy = vm.envAddress("PROXY_ADDRESS");
        require(proxy.code.length > 0, "proxy has no code");

        Options memory opts;
        opts.referenceBuildInfoDir = vm.envOr("REFERENCE_BUILD_INFO_DIR", string(""));
        opts.referenceContract = vm.envOr("REFERENCE_CONTRACT", string("L1FluentBridge.sol:L1FluentBridge"));
        opts.unsafeSkipStorageCheck = vm.envOr("UNSAFE_SKIP_STORAGE_CHECK", true);

        vm.startBroadcast();
        Upgrades.upgradeProxy(proxy, "L1FluentBridge.sol:L1FluentBridge", "", opts);
        vm.stopBroadcast();

        console2.log("Upgraded", proxy, "->", Upgrades.getImplementationAddress(proxy));
    }
}
