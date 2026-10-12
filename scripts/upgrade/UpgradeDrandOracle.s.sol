// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {DrandOracle} from "../../contracts/oracles/DrandOracle.sol";

/**
 * @notice Upgrades the DrandOracle proxy to the implementation in the current build.
 * @dev Env: PROXY_ADDRESS (required); REFERENCE_BUILD_INFO_DIR — a copy of `out/build-info` from
 *      the build of the implementation the proxy runs today, which the new layout is validated
 *      against (required unless UNSAFE_SKIP_STORAGE_CHECK=true, which skips the layout check
 *      and is for a reference build that cannot be reproduced). ADMIN_ROLE and EMERGENCY_ROLE:
 *      set them to make the upgrade call `initializeV2`, which seats the roles on a proxy the
 *      owner-based implementation initialized; the broadcaster must be that owner.
 */
contract UpgradeDrandOracle is Script {
    function run() external {
        address proxy = vm.envAddress("PROXY_ADDRESS");
        require(proxy.code.length > 0, "proxy has no code");
        bytes memory call;
        address admin = vm.envOr("ADMIN_ROLE", address(0));
        if (admin != address(0)) {
            address emergency = vm.envOr("EMERGENCY_ROLE", address(0));
            call = abi.encodeCall(DrandOracle.initializeV2, (admin, emergency));
            console2.log("  seating roles: admin", admin, "emergency", emergency);
        }

        Options memory opts;
        opts.unsafeSkipStorageCheck = vm.envOr("UNSAFE_SKIP_STORAGE_CHECK", false);
        if (!opts.unsafeSkipStorageCheck) {
            opts.referenceBuildInfoDir = vm.envString("REFERENCE_BUILD_INFO_DIR");
            string memory shortName = _shortName(opts.referenceBuildInfoDir);
            require(bytes(shortName).length != 0, "REFERENCE_BUILD_INFO_DIR names no directory");
            opts.referenceContract = string.concat(shortName, ":DrandOracle");
        }

        vm.startBroadcast();
        Upgrades.upgradeProxy(proxy, "DrandOracle.sol:DrandOracle", call, opts);
        vm.stopBroadcast();

        console2.log("Upgraded", proxy, "->", Upgrades.getImplementationAddress(proxy));
    }

    /// @dev The last path segment, which is how the validator names a reference build directory.
    function _shortName(string memory path) internal pure returns (string memory) {
        bytes memory b = bytes(path);
        uint256 end = b.length;
        while (end > 0 && b[end - 1] == "/") --end;
        uint256 start = end;
        while (start > 0 && b[start - 1] != "/") --start;
        bytes memory name = new bytes(end - start);
        for (uint256 i = start; i < end; ++i) {
            name[i - start] = b[i];
        }
        return string(name);
    }
}
