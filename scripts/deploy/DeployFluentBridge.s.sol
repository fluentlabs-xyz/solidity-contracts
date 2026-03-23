// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {DeployLib} from "./DeployLib.s.sol";

/**
 * @notice Deployment script for the FluentBridge contract behind an ERC1967 proxy.
 * @dev Environment:
 * - INITIAL_OWNER (address): fallback admin if ADMIN_ROLE is not set
 * - ADMIN_ROLE (address): DEFAULT_ADMIN_ROLE; defaults to INITIAL_OWNER
 * - PAUSER_ROLE (address): pauser; defaults to ADMIN_ROLE/INITIAL_OWNER
 * - RELAYER_ROLE (address): relayer; defaults to BRIDGE_AUTHORITY/ADMIN_ROLE/INITIAL_OWNER
 * - BRIDGE_AUTHORITY (address): legacy fallback for RELAYER_ROLE
 * - RECEIVE_MSG_DEADLINE (uint256): deadline for receiving messages; default 0
 * - OTHER_BRIDGE_PLACEHOLDER (address): placeholder for the other bridge; default 0x1
 * - L1_BLOCK_ORACLE (address): L1 block oracle; default 0
 * - OUTPUT_PATH (string): path to write deployment JSON; default empty
 */
contract DeployFluentBridge is DeployLib {
    function run() external returns (address bridgeProxy) {
        address initialOwner = vm.envExists("INITIAL_OWNER") ? vm.envAddress("INITIAL_OWNER") : address(0);
        address adminRole = vm.envOr("ADMIN_ROLE", initialOwner);
        address pauserRole = vm.envOr("PAUSER_ROLE", adminRole);
        address relayerRole = vm.envOr("RELAYER_ROLE", vm.envOr("BRIDGE_AUTHORITY", adminRole));
        uint256 receiveMessageDeadline = vm.envOr("RECEIVE_MSG_DEADLINE", uint256(0));
        address otherBridgePlaceholder = vm.envOr("OTHER_BRIDGE_PLACEHOLDER", address(0x1));
        address l1BlockOracle = vm.envOr("L1_BLOCK_ORACLE", address(0));
        address rollup = vm.envOr("ROLLUP", vm.envOr("ROLLUP_ADDRESS", address(0)));
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
