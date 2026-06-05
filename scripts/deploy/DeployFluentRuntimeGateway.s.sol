// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IFluentBridgeAdmin} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {FluentRuntimeGateway} from "../../contracts/gateways/FluentRuntimeGateway.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys FluentRuntimeGateway behind a UUPS proxy.
/// @dev Deployment also activates the gateway in the local bridge via `registerGateway`.
contract DeployFluentRuntimeGateway is DeployBase {
    struct FluentRuntimeGatewayResult {
        address gateway;
        address gatewayImpl;
    }

    function _deployFluentRuntimeGateway(address initialOwner, address bridgeAddress)
        internal
        returns (FluentRuntimeGatewayResult memory r)
    {
        r.gateway = Upgrades.deployUUPSProxy(
            "FluentRuntimeGateway.sol:FluentRuntimeGateway",
            abi.encodeCall(FluentRuntimeGateway.initialize, (initialOwner, bridgeAddress))
        );
        r.gatewayImpl = Upgrades.getImplementationAddress(r.gateway);
        IFluentBridgeAdmin(bridgeAddress).registerGateway(r.gateway);
    }

    /// @dev Standalone: INITIAL_OWNER and BRIDGE_ADDRESS required.
    function run() external virtual {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        address bridge = vm.envAddress("BRIDGE_ADDRESS");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying FluentRuntimeGateway");
        console2.log("  initialOwner:", initialOwner);
        console2.log("  bridge:", bridge);

        vm.startBroadcast();
        FluentRuntimeGatewayResult memory r = _deployFluentRuntimeGateway(initialOwner, bridge);
        vm.stopBroadcast();

        console2.log("FluentRuntimeGateway deployed:", r.gateway);
        console2.log("  impl:", r.gatewayImpl);
        console2.log("FluentRuntimeGateway activated in bridge:", bridge);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "fluent_runtime_gateway", r.gateway);
            out = vm.serializeAddress("deployment", "fluent_runtime_gateway_impl", r.gatewayImpl);
            vm.writeJson(out, outputPath);
        }
    }
}
