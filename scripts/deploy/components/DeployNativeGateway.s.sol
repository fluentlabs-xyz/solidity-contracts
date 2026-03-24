// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {DeployLib} from "./DeployLib.s.sol";
import {NativeGateway} from "../../../contracts/gateways/NativeGateway.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/**
 * @notice Deploys NativeGateway behind a UUPS proxy with full OZ upgrade validation.
 * @dev Environment:
 * - INITIAL_OWNER (address, required)
 * - BRIDGE_ADDRESS (address, required)
 * - OUTPUT_PATH (string, optional)
 */
contract DeployNativeGateway is DeployLib {
    function run() external returns (address gatewayProxy) {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        address bridgeAddress = vm.envAddress("BRIDGE_ADDRESS");
        require(initialOwner != address(0), "INITIAL_OWNER is zero");
        require(bridgeAddress != address(0), "BRIDGE_ADDRESS is zero");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        vm.startBroadcast();
        gatewayProxy = Upgrades.deployUUPSProxy(
            "NativeGateway.sol:NativeGateway",
            abi.encodeCall(NativeGateway.initialize, (initialOwner, bridgeAddress))
        );
        address gatewayImpl = Upgrades.getImplementationAddress(gatewayProxy);
        vm.stopBroadcast();

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "native_gateway_impl", gatewayImpl);
            out = vm.serializeAddress("deployment", "native_gateway", gatewayProxy);
            vm.writeJson(out, outputPath);
        }
    }
}
