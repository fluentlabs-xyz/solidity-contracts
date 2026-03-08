// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DeployLib} from "./DeployLib.s.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";

/**
 * @notice L1 gateway stack only: deploys ERC20TokenFactory + PaymentGateway. Bridge must be deployed separately.
 * @dev Environment:
 *   INITIAL_OWNER (address), BRIDGE_ADDRESS (address, required),
 *   OUTPUT_PATH (string, optional).
 */
contract DeployL1 is DeployLib {
    struct Deployment {
        address bridge;
        address bridgeImpl;
        address peggedImpl;
        address factoryImpl;
        address factory;
        address factoryBeacon;
        address gatewayImpl;
        address gateway;
        address mockToken;
    }

    function run() external returns (address gateway) {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        require(initialOwner != address(0), "INITIAL_OWNER required");
        address bridgeAddress = vm.envAddress("BRIDGE_ADDRESS");
        require(bridgeAddress != address(0), "BRIDGE_ADDRESS required");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        vm.startBroadcast();

        ERC20FactoryResult memory factoryResult = _deployERC20TokenFactory(initialOwner);

        PaymentGatewayResult memory gatewayResult = _deployPaymentGateway(initialOwner, bridgeAddress, factoryResult.factory);
        ERC20TokenFactory(factoryResult.factory).setPaymentGateway(gatewayResult.gateway);

        vm.stopBroadcast();

        gateway = gatewayResult.gateway;

        if (bytes(outputPath).length != 0) {
            Deployment memory d;
            d.bridge = bridgeAddress;
            d.bridgeImpl = address(0);
            d.peggedImpl = factoryResult.peggedImpl;
            d.factoryImpl = factoryResult.factoryImpl;
            d.factory = factoryResult.factory;
            d.factoryBeacon = factoryResult.factoryBeacon;
            d.gatewayImpl = gatewayResult.gatewayImpl;
            d.gateway = gatewayResult.gateway;
            d.mockToken = address(0);
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
        json = vm.serializeAddress("deployment", "mock_token", d.mockToken);
        vm.writeJson(json, outputPath);
    }
}
