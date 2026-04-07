// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {DeployLib} from "./DeployLib.s.sol";

/**
 * @notice Deploy only the L1 FluentBridge (UUPS proxy + implementation).
 * @dev Environment:
 * - INITIAL_OWNER (address, required) OR ADMIN_ROLE (address, required)
 * - ADMIN_ROLE (address, optional; defaults to INITIAL_OWNER)
 * - PAUSER_ROLE (address, optional; defaults to ADMIN_ROLE)
 * - RELAYER_ROLE (address, optional; defaults to BRIDGE_AUTHORITY/ADMIN_ROLE)
 * - BRIDGE_AUTHORITY (address, optional; legacy fallback for RELAYER_ROLE)
 * - OTHER_BRIDGE_PLACEHOLDER (address, optional; default 0x1)
 * - ROLLUP (address, required) (or ROLLUP_ADDRESS as fallback)
 * - RECEIVE_MSG_DEADLINE (uint, required, non-zero) — snapshotted into each L1->L2 message at send time
 * - OUTPUT_PATH (string, optional; default empty)
 * - ALLOW_UNSAFE_UPGRADES=true (required)
 */
contract DeployL1FluentBridge is DeployLib {
    function run() external returns (address bridgeProxy) {
        address initialOwner = vm.envExists("INITIAL_OWNER") ? vm.envAddress("INITIAL_OWNER") : address(0);
        address adminRole = vm.envOr("ADMIN_ROLE", initialOwner);
        require(adminRole != address(0), "ADMIN_ROLE/INITIAL_OWNER required");

        address pauserRole = vm.envOr("PAUSER_ROLE", adminRole);
        address relayerRole = vm.envOr("RELAYER_ROLE", vm.envOr("BRIDGE_AUTHORITY", adminRole));
        address otherBridgePlaceholder = vm.envOr("OTHER_BRIDGE_PLACEHOLDER", address(0x1));
        address l1BlockOracle = address(0);
        address rollup = vm.envOr("ROLLUP", vm.envOr("ROLLUP_ADDRESS", address(0)));
        uint256 receiveMessageDeadline = vm.envUint("RECEIVE_MSG_DEADLINE");
        require(receiveMessageDeadline > 0, "RECEIVE_MSG_DEADLINE required and must be > 0");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        vm.startBroadcast();
        address bridgeImpl;
        (bridgeProxy, bridgeImpl) = _deployFluentBridge(
            adminRole,
            pauserRole,
            relayerRole,
            receiveMessageDeadline,
            otherBridgePlaceholder,
            l1BlockOracle,
            rollup
        );
        vm.stopBroadcast();

        if (bytes(outputPath).length != 0) {
            string memory json = vm.serializeAddress("deployment", "bridge_impl", bridgeImpl);
            json = vm.serializeAddress("deployment", "bridge", bridgeProxy);
            vm.writeJson(json, outputPath);
        }
    }
}
