// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DeployLib} from "./DeployLib.s.sol";
import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";
import {UniversalTokenSDK} from "../../contracts/libraries/UniversalTokenSDK.sol";

/**
 * @notice L2 orchestrator: deploys UniversalTokenFactory, PaymentGateway; optionally FluentBridge if BRIDGE_ADDRESS not set.
 * @dev Environment:
 *   INITIAL_OWNER (address), BRIDGE_ADDRESS (address; if not set and DEPLOY_BRIDGE=true, bridge is deployed),
 *   DEPLOY_BRIDGE (bool, optional), BRIDGE_AUTHORITY (optional), RECEIVE_MSG_DEADLINE (optional),
 *   OTHER_BRIDGE_PLACEHOLDER (optional), L1_BLOCK_ORACLE (optional), OUTPUT_PATH (string, optional).
 */
contract DeployL2 is DeployLib {
    struct Deployment {
        address bridge;
        address bridgeImpl;
        address factoryImpl;
        address factory;
        address gatewayImpl;
        address gateway;
    }

    function run() external returns (address gateway) {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        address bridgeAddress = vm.envOr("BRIDGE_ADDRESS", address(0));
        bool deployBridge = vm.envOr("DEPLOY_BRIDGE", false);
        address bridgeAuthority = vm.envOr("BRIDGE_AUTHORITY", initialOwner);
        uint256 receiveMessageDeadline = vm.envOr("RECEIVE_MSG_DEADLINE", uint256(0));
        address otherBridgePlaceholder = vm.envOr("OTHER_BRIDGE_PLACEHOLDER", address(0x1));
        address l1BlockOracle = vm.envOr("L1_BLOCK_ORACLE", address(0));
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        vm.startBroadcast();

        address bridgeImpl = address(0);
        if (bridgeAddress == address(0) && deployBridge) {
            (bridgeAddress, bridgeImpl) = _deployFluentBridge(
                initialOwner,
                bridgeAuthority,
                receiveMessageDeadline,
                otherBridgePlaceholder,
                l1BlockOracle
            );
        }
        require(bridgeAddress != address(0), "BRIDGE_ADDRESS or DEPLOY_BRIDGE required");

        (address factoryProxy, address factoryImpl) = _deployUniversalTokenFactory(initialOwner);

        PaymentGatewayResult memory gatewayResult = _deployPaymentGateway(initialOwner, bridgeAddress, factoryProxy);
        UniversalTokenFactory(factoryProxy).setPaymentGateway(gatewayResult.gateway);

        vm.stopBroadcast();

        gateway = gatewayResult.gateway;

        if (bytes(outputPath).length != 0) {
            Deployment memory d;
            d.bridge = bridgeAddress;
            d.bridgeImpl = bridgeImpl;
            d.factoryImpl = factoryImpl;
            d.factory = factoryProxy;
            d.gatewayImpl = gatewayResult.gatewayImpl;
            d.gateway = gatewayResult.gateway;
            _writeOutput(outputPath, d);
        }
    }

    function _writeOutput(string memory outputPath, Deployment memory d) internal {
        string memory json = vm.serializeAddress("deployment", "bridge", d.bridge);
        json = vm.serializeAddress("deployment", "bridge_impl", d.bridgeImpl);
        json = vm.serializeAddress("deployment", "pegged_impl", UniversalTokenSDK.UNIVERSAL_TOKEN_RUNTIME);
        json = vm.serializeAddress("deployment", "factory_impl", d.factoryImpl);
        json = vm.serializeAddress("deployment", "factory", d.factory);
        json = vm.serializeAddress("deployment", "factory_beacon", address(0));
        json = vm.serializeAddress("deployment", "gateway_impl", d.gatewayImpl);
        json = vm.serializeAddress("deployment", "gateway", d.gateway);
        json = vm.serializeAddress("deployment", "mock_token", address(0));
        vm.writeJson(json, outputPath);
    }
}
