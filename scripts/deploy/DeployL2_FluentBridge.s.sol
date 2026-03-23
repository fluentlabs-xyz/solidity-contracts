// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {DeployLib} from "./DeployLib.s.sol";

/**
 * @notice Deploy only the L2 FluentBridge (UUPS proxy + implementation).
 * @dev Environment:
 * - INITIAL_OWNER (address, required) OR ADMIN_ROLE (address, required)
 * - ADMIN_ROLE (address, optional; defaults to INITIAL_OWNER)
 * - PAUSER_ROLE (address, optional; defaults to ADMIN_ROLE)
 * - RELAYER_ROLE (address, optional; defaults to BRIDGE_AUTHORITY/ADMIN_ROLE)
 * - BRIDGE_AUTHORITY (address, optional; legacy fallback for RELAYER_ROLE)
 * - OTHER_BRIDGE_PLACEHOLDER (address, optional; default 0x1)
 * - RECEIVE_MSG_DEADLINE (uint256, required, non-zero)
 * - L1_BLOCK_ORACLE (address, required)
 * - L1 gas price oracle: {DeployLib} auto-deploys {L1GasOracle} (submitter = RELAYER_ROLE) and wires it into {L2FluentBridge}.
 *   For custom gas scalar/overhead/treasury, call the 11-argument {DeployLib._deployFluentBridge} from a dedicated script.
 * - OUTPUT_PATH (string, optional; default empty)
 * - ALLOW_UNSAFE_UPGRADES=true (required)
 */
contract DeployL2FluentBridge is DeployLib {
    function run() external returns (address bridgeProxy) {
        address initialOwner = vm.envExists("INITIAL_OWNER") ? vm.envAddress("INITIAL_OWNER") : address(0);
        address adminRole = vm.envOr("ADMIN_ROLE", initialOwner);
        require(adminRole != address(0), "ADMIN_ROLE/INITIAL_OWNER required");

        address pauserRole = vm.envOr("PAUSER_ROLE", adminRole);
        address relayerRole = vm.envOr("RELAYER_ROLE", vm.envOr("BRIDGE_AUTHORITY", adminRole));
        address otherBridgePlaceholder = vm.envOr("OTHER_BRIDGE_PLACEHOLDER", address(0x1));
        uint256 receiveMessageDeadline = vm.envUint("RECEIVE_MSG_DEADLINE");
        require(receiveMessageDeadline != 0, "RECEIVE_MSG_DEADLINE required");
        address l1BlockOracle = vm.envAddress("L1_BLOCK_ORACLE");
        address rollup = address(0);
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
