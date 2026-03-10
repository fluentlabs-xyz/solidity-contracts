// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DeployLib} from "./DeployLib.s.sol";

/**
 * @notice Deployment script for the FluentBridge contract behind an ERC1967 proxy.
 * @dev Environment:
 * - INITIAL_OWNER (address): owner of the FluentBridge
 * - BRIDGE_AUTHORITY (address): authority; defaults to INITIAL_OWNER
 * - RECEIVE_MSG_DEADLINE (uint256): deadline for receiving messages; default 0
 * - OTHER_BRIDGE_PLACEHOLDER (address): placeholder for the other bridge; default 0x1
 * - L1_BLOCK_ORACLE (address): L1 block oracle; default 0
 * - OUTPUT_PATH (string): path to write deployment JSON; default empty
 */
contract DeployFluentBridge is DeployLib {
    function run() external returns (address bridgeProxy) {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        address bridgeAuthority = vm.envOr("BRIDGE_AUTHORITY", initialOwner);
        uint256 receiveMessageDeadline = vm.envOr("RECEIVE_MSG_DEADLINE", uint256(0));
        address otherBridgePlaceholder = vm.envOr("OTHER_BRIDGE_PLACEHOLDER", address(0x1));
        address l1BlockOracle = vm.envOr("L1_BLOCK_ORACLE", address(0));
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        vm.startBroadcast();
        address bridgeImpl;
        (bridgeProxy, bridgeImpl) = _deployFluentBridge(
            initialOwner, bridgeAuthority, receiveMessageDeadline, otherBridgePlaceholder, l1BlockOracle
        );
        vm.stopBroadcast();

        if (bytes(outputPath).length != 0) {
            string memory json = vm.serializeAddress("deployment", "bridge_impl", bridgeImpl);
            json = vm.serializeAddress("deployment", "bridge", bridgeProxy);
            vm.writeJson(json, outputPath);
        }
    }
}
