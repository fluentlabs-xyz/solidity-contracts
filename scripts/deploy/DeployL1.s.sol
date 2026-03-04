// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseScript} from "../Base.sol";
import {PaymentsGateway} from "../../contracts/gateways/PaymentsGateway.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {MockERC20Token} from "../../contracts/mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract DeployL1 is BaseScript {
    struct Deployment {
        address peggedImpl;
        address factoryImpl;
        address factory;
        address factoryBeacon;
        address gatewayImpl;
        address gateway;
        address mockToken;
    }

    event GatewayStackDeployed(address indexed factory, address indexed gateway, address indexed beacon);
    event MockTokenDeployed(address indexed token);

    function run() external returns (address gatewayProxyAddress) {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        address bridgeAddress = vm.envAddress("BRIDGE_ADDRESS");
        bool deployMock = vm.envOr("DEPLOY_MOCK", false);
        uint256 mockSupply = vm.envOr("MOCK_SUPPLY", uint256(100_000_000 ether));
        address mockRecipient = vm.envOr("MOCK_RECIPIENT", initialOwner);
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        Deployment memory deployed =
            _deployGatewayStack(initialOwner, bridgeAddress, deployMock, mockSupply, mockRecipient);

        gatewayProxyAddress = deployed.gateway;
        emit GatewayStackDeployed(deployed.factory, deployed.gateway, deployed.factoryBeacon);

        if (bytes(outputPath).length != 0) {
            _writeOutput(outputPath, deployed);
        }
    }

    function _deployGatewayStack(
        address initialOwner,
        address bridgeAddress,
        bool deployMock,
        uint256 mockSupply,
        address mockRecipient
    ) internal returns (Deployment memory deployed) {
        vm.startBroadcast();

        ERC20PeggedToken peggedTokenImplementation = new ERC20PeggedToken();
        ERC20TokenFactory factoryImplementation = new ERC20TokenFactory();
        ERC1967Proxy factoryProxyContract = new ERC1967Proxy(
            address(factoryImplementation),
            abi.encodeCall(ERC20TokenFactory.initialize, (initialOwner, address(peggedTokenImplementation)))
        );

        ERC20TokenFactory factoryProxy = ERC20TokenFactory(address(factoryProxyContract));
        UpgradeableBeacon beacon = UpgradeableBeacon(factoryProxy.beacon());

        PaymentsGateway gatewayImplementation = new PaymentsGateway();
        ERC1967Proxy gatewayProxyContract = new ERC1967Proxy(
            address(gatewayImplementation),
            abi.encodeCall(PaymentsGateway.initialize, (initialOwner, bridgeAddress, address(factoryProxy)))
        );

        factoryProxy.transferOwnership(address(gatewayProxyContract));
        PaymentsGateway(payable(address(gatewayProxyContract))).acceptTokenFactory();

        address mockTokenAddress = address(0);
        if (deployMock) {
            MockERC20Token token = new MockERC20Token("Mock Deposit Token", "MDT", mockSupply, mockRecipient);
            mockTokenAddress = address(token);
            emit MockTokenDeployed(mockTokenAddress);
        }

        vm.stopBroadcast();

        deployed.peggedImpl = address(peggedTokenImplementation);
        deployed.factoryImpl = address(factoryImplementation);
        deployed.factory = address(factoryProxy);
        deployed.factoryBeacon = address(beacon);
        deployed.gatewayImpl = address(gatewayImplementation);
        deployed.gateway = address(gatewayProxyContract);
        deployed.mockToken = mockTokenAddress;
    }

    function _writeOutput(string memory outputPath, Deployment memory deployed) internal {
        string memory json = vm.serializeAddress("deployment", "pegged_impl", deployed.peggedImpl);
        json = vm.serializeAddress("deployment", "factory_impl", deployed.factoryImpl);
        json = vm.serializeAddress("deployment", "factory", deployed.factory);
        json = vm.serializeAddress("deployment", "factory_beacon", deployed.factoryBeacon);
        json = vm.serializeAddress("deployment", "gateway_impl", deployed.gatewayImpl);
        json = vm.serializeAddress("deployment", "gateway", deployed.gateway);
        json = vm.serializeAddress("deployment", "mock_token", deployed.mockToken);
        vm.writeJson(json, outputPath);
    }
}
