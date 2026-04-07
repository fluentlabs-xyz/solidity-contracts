// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {NativeGateway} from "../../contracts/gateways/NativeGateway.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys NativeGateway behind a UUPS proxy.
/// @dev Inherit and call _deployNativeGateway() inside your broadcast.
contract DeployNativeGateway is DeployBase {
    struct NativeGatewayResult {
        address gateway;
        address gatewayImpl;
    }

    function _deployNativeGateway(address initialOwner, address bridgeAddress) internal returns (NativeGatewayResult memory r) {
        r.gateway = Upgrades.deployUUPSProxy(
            "NativeGateway.sol:NativeGateway",
            abi.encodeCall(NativeGateway.initialize, (initialOwner, bridgeAddress))
        );
        r.gatewayImpl = Upgrades.getImplementationAddress(r.gateway);
    }

    /// @dev Standalone: INITIAL_OWNER, BRIDGE_ADDRESS required.
    function run() external virtual {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        address bridge = vm.envAddress("BRIDGE_ADDRESS");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying NativeGateway");
        console2.log("  initialOwner:", initialOwner);
        console2.log("  bridge:", bridge);

        vm.startBroadcast();
        NativeGatewayResult memory r = _deployNativeGateway(initialOwner, bridge);
        vm.stopBroadcast();

        console2.log("NativeGateway deployed:", r.gateway);
        console2.log("  impl:", r.gatewayImpl);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "native_gateway", r.gateway);
            out = vm.serializeAddress("deployment", "native_gateway_impl", r.gatewayImpl);
            vm.writeJson(out, outputPath);
        }
    }
}
