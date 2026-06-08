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

    function _deployFluentRuntimeGateway(
        address initialOwner,
        address bridgeAddress,
        address blendToken,
        address feeRecipient,
        uint256 deployBaseFee,
        uint256 deployFeePerByte,
        uint256 invokeBaseFee,
        uint256 invokeFeePerByte
    ) internal returns (FluentRuntimeGatewayResult memory r) {
        r.gateway = Upgrades.deployUUPSProxy(
            "FluentRuntimeGateway.sol:FluentRuntimeGateway",
            abi.encodeCall(FluentRuntimeGateway.initialize, (initialOwner, bridgeAddress))
        );
        r.gatewayImpl = Upgrades.getImplementationAddress(r.gateway);
        FluentRuntimeGateway(payable(r.gateway))
            .setBlendFeeConfig(
                blendToken, feeRecipient, deployBaseFee, deployFeePerByte, invokeBaseFee, invokeFeePerByte
            );
        IFluentBridgeAdmin(bridgeAddress).registerGateway(r.gateway);
    }

    /// @dev Standalone: INITIAL_OWNER, BRIDGE_ADDRESS, BLEND_TOKEN, and FEE_RECIPIENT required.
    function run() external virtual {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        address bridge = vm.envAddress("BRIDGE_ADDRESS");
        address blendToken = vm.envAddress("BLEND_TOKEN");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 deployBaseFee = vm.envOr("DEPLOY_BASE_FEE", uint256(0));
        uint256 deployFeePerByte = vm.envOr("DEPLOY_FEE_PER_BYTE", uint256(0));
        uint256 invokeBaseFee = vm.envOr("INVOKE_BASE_FEE", uint256(0));
        uint256 invokeFeePerByte = vm.envOr("INVOKE_FEE_PER_BYTE", uint256(0));
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying FluentRuntimeGateway");
        console2.log("  initialOwner:", initialOwner);
        console2.log("  bridge:", bridge);
        console2.log("  blendToken:", blendToken);
        console2.log("  feeRecipient:", feeRecipient);

        vm.startBroadcast();
        FluentRuntimeGatewayResult memory r = _deployFluentRuntimeGateway(
            initialOwner,
            bridge,
            blendToken,
            feeRecipient,
            deployBaseFee,
            deployFeePerByte,
            invokeBaseFee,
            invokeFeePerByte
        );
        vm.stopBroadcast();

        console2.log("FluentRuntimeGateway deployed:", r.gateway);
        console2.log("  impl:", r.gatewayImpl);
        console2.log("FluentRuntimeGateway activated in bridge:", bridge);
        console2.log("BLEND fee config set");

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "fluent_runtime_gateway", r.gateway);
            out = vm.serializeAddress("deployment", "fluent_runtime_gateway_impl", r.gatewayImpl);
            vm.writeJson(out, outputPath);
        }
    }
}
