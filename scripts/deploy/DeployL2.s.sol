// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DeployLib} from "./DeployLib.s.sol";
import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";
import {UniversalTokenSDK} from "../../contracts/libraries/UniversalTokenSDK.sol";

/**
 * @notice L2 deploy orchestrator (Fluent-style): bridge + universal factory + gateway.
 * @dev Mirrors scripts/deploy/bash/fluent_deploy.bash deployment steps in Solidity.
 *      Environment:
 *      - INITIAL_OWNER (address, required)
 *      - BRIDGE_AUTHORITY (address, optional; defaults to INITIAL_OWNER)
 *      - RECEIVE_MSG_DEADLINE (uint256, optional; default 0)
 *      - OTHER_BRIDGE_PLACEHOLDER (address, optional; default 0x1)
 *      - L1_BLOCK_ORACLE (address, optional; default 0)
 *      - OUTPUT_PATH (string, optional; default "deployments/fluent_testnet.json")
 */
contract DeployL2 is DeployLib {
    struct Deployment {
        address bridge;
        address bridgeImpl;
        address peggedImpl;
        address factoryImpl;
        address factory;
        address factoryBeacon;
        address gatewayImpl;
        address gateway;
    }

    function run() external returns (address gateway) {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        require(initialOwner != address(0), "INITIAL_OWNER required");

        address bridgeAuthority = vm.envOr("BRIDGE_AUTHORITY", initialOwner);
        uint256 receiveMessageDeadline = vm.envOr("RECEIVE_MSG_DEADLINE", uint256(0));
        address otherBridgePlaceholder = vm.envOr("OTHER_BRIDGE_PLACEHOLDER", address(0x1));
        address l1BlockOracle = vm.envOr("L1_BLOCK_ORACLE", address(0));
        string memory outputPath = vm.envOr("OUTPUT_PATH", string("deployments/fluent_testnet.json"));

        vm.startBroadcast();

        (address bridgeProxy, address bridgeImpl) = _deployFluentBridge(
            initialOwner, bridgeAuthority, receiveMessageDeadline, otherBridgePlaceholder, l1BlockOracle
        );

        (address factoryProxy, address factoryImpl) = _deployUniversalTokenFactory(initialOwner);
        PaymentGatewayResult memory gatewayResult = _deployPaymentGateway(initialOwner, bridgeProxy, factoryProxy);
        UniversalTokenFactory(factoryProxy).setPaymentGateway(gatewayResult.gateway);

        vm.stopBroadcast();

        gateway = gatewayResult.gateway;

        if (bytes(outputPath).length != 0) {
            Deployment memory d;
            d.bridge = bridgeProxy;
            d.bridgeImpl = bridgeImpl;
            d.peggedImpl = UniversalTokenSDK.UNIVERSAL_TOKEN_RUNTIME;
            d.factoryImpl = factoryImpl;
            d.factory = factoryProxy;
            d.factoryBeacon = address(0);
            d.gatewayImpl = gatewayResult.gatewayImpl;
            d.gateway = gatewayResult.gateway;
            _writeOutput(outputPath, d);
        }
    }

    function _writeOutput(string memory outputPath, Deployment memory d) internal {
        string memory json = vm.serializeAddress("deployment", "bridge", d.bridge);
        json = vm.serializeAddress("deployment", "bridge_impl", d.bridgeImpl);
        json = vm.serializeAddress("deployment", "pegged_impl", d.peggedImpl);
        json = vm.serializeAddress("deployment", "factory_impl", d.factoryImpl);
        json = vm.serializeAddress("deployment", "factory", d.factory);
        json = vm.serializeAddress("deployment", "factory_beacon", d.factoryBeacon);
        json = vm.serializeAddress("deployment", "gateway_impl", d.gatewayImpl);
        json = vm.serializeAddress("deployment", "gateway", d.gateway);
        vm.writeJson(json, outputPath);
    }
}
