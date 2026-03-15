// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DeployLib} from "./DeployLib.s.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";

/**
 * @notice L1 deploy orchestrator (Sepolia-style): bridge + ERC20 factory + gateway + mock token.
 * @dev Mirrors scripts/deploy/bash/sepolia_deploy.bash deployment steps in Solidity.
 *      Environment:
 *      - INITIAL_OWNER (address, required)
 *      - PAUSER_ROLE (address, optional; defaults to ADMIN_ROLE/INITIAL_OWNER)
 *      - RELAYER_ROLE (address, optional; defaults to BRIDGE_AUTHORITY/ADMIN_ROLE/INITIAL_OWNER)
 *      - BRIDGE_AUTHORITY (address, optional; legacy fallback for RELAYER_ROLE)
 *      - RECEIVE_MSG_DEADLINE (uint256, optional; default 0)
 *      - OTHER_BRIDGE_PLACEHOLDER (address, optional; default 0x1)
 *      - L1_BLOCK_ORACLE (address, optional; default 0)
 *      - MOCK_ERC20_NAME (string, optional; default "Mock Deposit Token")
 *      - MOCK_ERC20_SYMBOL (string, optional; default "MDT")
 *      - MOCK_ERC20_SUPPLY (uint256, optional; default 1_000_000 ether)
 *      - MOCK_ERC20_RECIPIENT (address, optional; defaults to INITIAL_OWNER)
 *      - OUTPUT_PATH (string, optional; default "deployments/sepolia.json")
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
        address mockErc20;
        address mockToken;
    }

    function run() external returns (address gateway) {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        require(initialOwner != address(0), "INITIAL_OWNER required");

        address adminRole = vm.envOr("ADMIN_ROLE", initialOwner);
        address pauserRole = vm.envOr("PAUSER_ROLE", adminRole);
        address relayerRole = vm.envOr("RELAYER_ROLE", vm.envOr("BRIDGE_AUTHORITY", adminRole));
        uint256 receiveMessageDeadline = vm.envOr("RECEIVE_MSG_DEADLINE", uint256(0));
        address otherBridgePlaceholder = vm.envOr("OTHER_BRIDGE_PLACEHOLDER", address(0x1));
        address l1BlockOracle = vm.envOr("L1_BLOCK_ORACLE", address(0));

        string memory mockName = vm.envOr("MOCK_ERC20_NAME", string("Mock Deposit Token"));
        string memory mockSymbol = vm.envOr("MOCK_ERC20_SYMBOL", string("MDT"));
        uint256 mockSupply = vm.envOr("MOCK_ERC20_SUPPLY", uint256(1_000_000 ether));
        address mockRecipient = vm.envOr("MOCK_ERC20_RECIPIENT", initialOwner);
        string memory outputPath = vm.envOr("OUTPUT_PATH", string("deployments/sepolia.json"));

        vm.startBroadcast();

        (address bridgeProxy, address bridgeImpl) = _deployFluentBridge(
            adminRole,
            pauserRole,
            relayerRole,
            receiveMessageDeadline,
            otherBridgePlaceholder,
            l1BlockOracle
        );

        ERC20FactoryResult memory factoryResult = _deployERC20TokenFactory(initialOwner);
        PaymentGatewayResult memory gatewayResult = _deployPaymentGateway(initialOwner, bridgeProxy, factoryResult.factory);
        ERC20TokenFactory(factoryResult.factory).setPaymentGateway(gatewayResult.gateway);

        vm.stopBroadcast();

        gateway = gatewayResult.gateway;

        if (bytes(outputPath).length != 0) {
            Deployment memory d;
            d.bridge = bridgeProxy;
            d.bridgeImpl = bridgeImpl;
            d.peggedImpl = factoryResult.peggedImpl;
            d.factoryImpl = factoryResult.factoryImpl;
            d.factory = factoryResult.factory;
            d.factoryBeacon = factoryResult.factoryBeacon;
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
        json = vm.serializeAddress("deployment", "mock_token", d.mockToken);
        vm.writeJson(json, outputPath);
    }
}
