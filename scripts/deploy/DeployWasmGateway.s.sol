// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {WasmGateway} from "../../contracts/gateways/WasmGateway.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys WasmGateway behind a UUPS proxy.
/// @dev `RUNTIME_ADDRESS` may be address(0) on the source-chain gateway. The destination
///      gateway must be configured with the Fluent Runtime endpoint before relayed messages execute.
contract DeployWasmGateway is DeployBase {
    struct WasmGatewayResult {
        address gateway;
        address gatewayImpl;
    }

    function _deployWasmGateway(address initialOwner, address bridgeAddress, address runtimeAddress)
        internal
        returns (WasmGatewayResult memory r)
    {
        r.gateway = Upgrades.deployUUPSProxy(
            "WasmGateway.sol:WasmGateway",
            abi.encodeCall(WasmGateway.initialize, (initialOwner, bridgeAddress, runtimeAddress))
        );
        r.gatewayImpl = Upgrades.getImplementationAddress(r.gateway);
    }

    /// @dev Standalone: INITIAL_OWNER, BRIDGE_ADDRESS required. RUNTIME_ADDRESS optional.
    function run() external virtual {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        address bridge = vm.envAddress("BRIDGE_ADDRESS");
        address runtime = vm.envOr("RUNTIME_ADDRESS", address(0));
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying WasmGateway");
        console2.log("  initialOwner:", initialOwner);
        console2.log("  bridge:", bridge);
        console2.log("  runtime:", runtime);

        vm.startBroadcast();
        WasmGatewayResult memory r = _deployWasmGateway(initialOwner, bridge, runtime);
        vm.stopBroadcast();

        console2.log("WasmGateway deployed:", r.gateway);
        console2.log("  impl:", r.gatewayImpl);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "wasm_gateway", r.gateway);
            out = vm.serializeAddress("deployment", "wasm_gateway_impl", r.gatewayImpl);
            vm.writeJson(out, outputPath);
        }
    }
}
