// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {L1HypNativeGateway} from "../../contracts/gateways/L1HypNativeGateway.sol";
import {L2HypNativeGateway} from "../../contracts/gateways/L2HypNativeGateway.sol";

import {DeployBase} from "./DeployBase.s.sol";

/**
 * @notice Deploys the native ETH Hyperlane gateway pair behind UUPS proxies.
 * @dev Mirrors DeployNativeGateway. The L1 and L2 sides are different contracts, so this
 *      script exposes two internal helpers and a `run()` that picks based on `LAYER` env.
 *
 *      Standalone usage:
 *        LAYER=L1 INITIAL_OWNER=0x.. BRIDGE_ADDRESS=0x.. forge script DeployHypNativeGateway.s.sol
 *        LAYER=L2 INITIAL_OWNER=0x.. BRIDGE_ADDRESS=0x.. forge script DeployHypNativeGateway.s.sol
 */
contract DeployHypNativeGateway is DeployBase {
    struct HypNativeGatewayResult {
        address gateway;
        address gatewayImpl;
    }

    function _deployL1HypNativeGateway(address initialOwner, address bridgeAddress)
        internal
        returns (HypNativeGatewayResult memory r)
    {
        r.gateway = Upgrades.deployUUPSProxy(
            "L1HypNativeGateway.sol:L1HypNativeGateway",
            abi.encodeCall(L1HypNativeGateway.initialize, (initialOwner, bridgeAddress))
        );
        r.gatewayImpl = Upgrades.getImplementationAddress(r.gateway);
    }

    function _deployL2HypNativeGateway(address initialOwner, address bridgeAddress)
        internal
        returns (HypNativeGatewayResult memory r)
    {
        r.gateway = Upgrades.deployUUPSProxy(
            "L2HypNativeGateway.sol:L2HypNativeGateway",
            abi.encodeCall(L2HypNativeGateway.initialize, (initialOwner, bridgeAddress))
        );
        r.gatewayImpl = Upgrades.getImplementationAddress(r.gateway);
    }

    /// @dev Standalone entrypoint. Required env: INITIAL_OWNER, BRIDGE_ADDRESS, LAYER (L1|L2).
    function run() external virtual {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        address bridge = vm.envAddress("BRIDGE_ADDRESS");
        string memory layer = vm.envString("LAYER");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        require(initialOwner != address(0), "INITIAL_OWNER is zero");
        require(bridge.code.length > 0, "BRIDGE_ADDRESS has no code");

        bool isL1 = keccak256(bytes(layer)) == keccak256("L1");
        bool isL2 = keccak256(bytes(layer)) == keccak256("L2");
        require(isL1 || isL2, "LAYER must be L1 or L2");

        console2.log(isL1 ? "Deploying L1HypNativeGateway" : "Deploying L2HypNativeGateway");
        console2.log("  initialOwner:", initialOwner);
        console2.log("  bridge:", bridge);

        vm.startBroadcast();
        HypNativeGatewayResult memory r = isL1
            ? _deployL1HypNativeGateway(initialOwner, bridge)
            : _deployL2HypNativeGateway(initialOwner, bridge);
        vm.stopBroadcast();

        console2.log(isL1 ? "L1HypNativeGateway deployed:" : "L2HypNativeGateway deployed:", r.gateway);
        console2.log("  impl:", r.gatewayImpl);

        if (bytes(outputPath).length != 0) {
            string memory key = isL1 ? "l1_hyp_native_gateway" : "l2_hyp_native_gateway";
            string memory implKey = isL1 ? "l1_hyp_native_gateway_impl" : "l2_hyp_native_gateway_impl";
            string memory out = vm.serializeAddress("deployment", key, r.gateway);
            out = vm.serializeAddress("deployment", implKey, r.gatewayImpl);
            vm.writeJson(out, outputPath);
        }
    }
}
