// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseScript} from "../Base.sol";
import {FluentBridge} from "../../contracts/FluentBridge.sol";
import {PaymentGateway} from "../../contracts/gateways/PaymentGateway.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";
import {MockERC20Token} from "../../contracts/mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/**
 * @notice Shared deployment logic for L1/L2 stacks. No broadcast; caller must vm.startBroadcast/stopBroadcast.
 */
abstract contract DeployLib is BaseScript {
    struct ERC20FactoryResult {
        address factory;
        address factoryImpl;
        address factoryBeacon;
        address peggedImpl;
    }

    struct PaymentGatewayResult {
        address gateway;
        address gatewayImpl;
    }

    /// @dev Deploys FluentBridge impl + proxy. Caller must be in broadcast. Returns (proxy, impl).
    function _deployFluentBridge(
        address initialOwner,
        address bridgeAuthority,
        uint256 receiveMessageDeadline,
        address otherBridgePlaceholder,
        address l1BlockOracle
    ) internal returns (address bridgeProxy, address bridgeImpl) {
        FluentBridge impl = new FluentBridge();
        FluentBridge.InitConfiguration memory params = FluentBridge.InitConfiguration({
            initialOwner: initialOwner,
            bridgeAuthority: bridgeAuthority,
            rollup: address(0),
            receiveMessageDeadline: receiveMessageDeadline,
            otherBridge: otherBridgePlaceholder,
            l1BlockOracle: l1BlockOracle
        });
        bytes memory initData = abi.encode(params);
        ERC1967Proxy proxyContract = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(FluentBridge.initialize, (initData))
        );
        return (address(proxyContract), address(impl));
    }

    /// @dev Deploys ERC20 factory stack (L1): pegged impl, beacon, factory impl, factory proxy. Caller must be in broadcast.
    function _deployERC20TokenFactory(address initialOwner) internal returns (ERC20FactoryResult memory r) {
        ERC20PeggedToken peggedImpl = new ERC20PeggedToken();
        ERC20TokenFactory factoryImpl = new ERC20TokenFactory();
        ERC1967Proxy factoryProxyContract = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(ERC20TokenFactory.initialize, (initialOwner, address(peggedImpl)))
        );
        ERC20TokenFactory factoryProxy = ERC20TokenFactory(address(factoryProxyContract));
        r.factory = address(factoryProxy);
        r.factoryImpl = address(factoryImpl);
        r.factoryBeacon = factoryProxy.beacon();
        r.peggedImpl = address(peggedImpl);
    }

    /// @dev Deploys UniversalTokenFactory (L2): impl + proxy. Caller must be in broadcast.
    function _deployUniversalTokenFactory(address initialOwner) internal returns (address factoryProxy, address factoryImpl) {
        UniversalTokenFactory impl = new UniversalTokenFactory();
        ERC1967Proxy proxyContract = new ERC1967Proxy(address(impl), abi.encodeCall(UniversalTokenFactory.initialize, (initialOwner)));
        return (address(proxyContract), address(impl));
    }

    /// @dev Deploys PaymentGateway impl + proxy. Caller must call factory.setPaymentGateway(gateway) after.
    function _deployPaymentGateway(
        address initialOwner,
        address bridgeAddress,
        address factoryAddress
    ) internal returns (PaymentGatewayResult memory r) {
        PaymentGateway gatewayImpl = new PaymentGateway();
        ERC1967Proxy gatewayProxyContract = new ERC1967Proxy(
            address(gatewayImpl),
            abi.encodeCall(PaymentGateway.initialize, (initialOwner, bridgeAddress, factoryAddress))
        );
        r.gateway = address(gatewayProxyContract);
        r.gatewayImpl = address(gatewayImpl);
    }

    /// @dev Deploys a mock ERC20. Caller must be in broadcast.
    function _deployMockERC20(string memory name, string memory symbol, uint256 supply, address recipient) internal returns (address token) {
        MockERC20Token t = new MockERC20Token(name, symbol, supply, recipient);
        return address(t);
    }
}
