// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";

import {DeployLib} from "./DeployLib.s.sol";

/**
 * @notice Deploy only the L1 FluentBridge (UUPS proxy + implementation).
 * @dev Reads chain config from scripts/input/<NETWORK>.json. Env vars override JSON values.
 *      Requires ALLOW_UNSAFE_UPGRADES=true.
 */
contract DeployL1FluentBridge is DeployLib {
    using stdJson for string;

    function run() external returns (address bridgeProxy) {
        string memory network = vm.envOr("NETWORK", string("testnet/l1"));
        string memory json = _readConfig(network);
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        address adminRole = vm.envOr("ADMIN_ROLE", json.readAddress(".roles.admin"));
        require(adminRole != address(0), "ADMIN_ROLE required");

        address pauserRole = vm.envOr("PAUSER_ROLE", json.readAddress(".roles.pauser"));
        address relayerRole = vm.envOr("RELAYER_ROLE", json.readAddress(".roles.relayer"));
        address otherBridgePlaceholder = vm.envOr("OTHER_BRIDGE_PLACEHOLDER", address(0x1));
        address rollup = vm.envOr("ROLLUP", address(0));

        vm.startBroadcast();
        address bridgeImpl;
        (bridgeProxy, bridgeImpl) = _deployFluentBridge(adminRole, pauserRole, relayerRole, 0, otherBridgePlaceholder, address(0), rollup);
        vm.stopBroadcast();

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "bridge_impl", bridgeImpl);
            out = vm.serializeAddress("deployment", "bridge", bridgeProxy);
            vm.writeJson(out, outputPath);
        }
    }
}
