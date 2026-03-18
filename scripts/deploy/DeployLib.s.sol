// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";

import {Upgrades, UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";

import {FluentBridge} from "../../contracts/bridge/FluentBridge.sol";
import {PaymentGateway} from "../../contracts/gateways/PaymentGateway.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";
import {MockERC20Token} from "../../contracts/mocks/MockERC20.sol";

/**
 * @notice Shared deployment logic for L1/L2 stacks. No broadcast; caller must vm.startBroadcast/stopBroadcast.
 * @dev Uses Upgrades.deployUUPSProxy(contractName, ...) with unsafeSkipAllChecks where vm.getCode(contractName) works.
 *      All unsafe upgrade flows require ALLOW_UNSAFE_UPGRADES=true so operators cannot
 *      accidentally skip storage and upgrade safety validations during deployment.
 *      UniversalTokenFactory uses UniversalTokenSDK (unlinked artifact); it uses UnsafeUpgrades.deployUUPSProxy(impl, ...) with new Impl().
 */
abstract contract DeployLib is Script {
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

    /// @dev Contract name for Upgrades lib: Foundry artifact is out/<ContractName>.sol/<ContractName>.json (no contracts/ prefix)
    string constant FLUENT_BRIDGE = "FluentBridge.sol:FluentBridge";
    string constant PAYMENT_GATEWAY = "PaymentGateway.sol:PaymentGateway";
    string constant ERC20_TOKEN_FACTORY = "ERC20TokenFactory.sol:ERC20TokenFactory";
    string constant UNIVERSAL_TOKEN_FACTORY = "UniversalTokenFactory.sol:UniversalTokenFactory";

    function _upgradesOpts() internal view returns (Options memory opts) {
        _requireUnsafeUpgradeApproval();
        opts.unsafeSkipAllChecks = true;
    }

    function _requireUnsafeUpgradeApproval() internal view {
        require(vm.envOr("ALLOW_UNSAFE_UPGRADES", false), "ALLOW_UNSAFE_UPGRADES=true required");
    }

    /// @dev Deploys FluentBridge via UUPS proxy. Caller must be in broadcast. Returns (proxy, impl).
    function _deployFluentBridge(
        address adminRole,
        address pauserRole,
        address relayerRole,
        uint256 receiveMessageDeadline,
        address otherBridgePlaceholder,
        address l1BlockOracle
    ) internal returns (address bridgeProxy, address bridgeImpl) {
        FluentBridge.InitConfiguration memory params = FluentBridge.InitConfiguration({
            adminRole: adminRole,
            pauserRole: pauserRole,
            relayerRole: relayerRole,
            rollup: address(0),
            otherBridge: otherBridgePlaceholder
        });
        bytes memory initData = abi.encode(params);
        bytes memory initializerData = abi.encodeCall(FluentBridge.initialize, (initData));
        bridgeProxy = Upgrades.deployUUPSProxy(FLUENT_BRIDGE, initializerData, _upgradesOpts());
        bridgeImpl = Upgrades.getImplementationAddress(bridgeProxy);
    }

    /// @dev Deploys ERC20 factory stack (L1): pegged impl, then factory UUPS proxy (factory creates beacon in initialize). Caller must be in broadcast.
    function _deployERC20TokenFactory(address initialOwner) internal returns (ERC20FactoryResult memory r) {
        ERC20PeggedToken peggedImpl = new ERC20PeggedToken();
        r.peggedImpl = address(peggedImpl);
        bytes memory initializerData = abi.encodeCall(ERC20TokenFactory.initialize, (initialOwner, address(peggedImpl)));
        r.factory = Upgrades.deployUUPSProxy(ERC20_TOKEN_FACTORY, initializerData, _upgradesOpts());
        r.factoryImpl = Upgrades.getImplementationAddress(r.factory);
        r.factoryBeacon = ERC20TokenFactory(r.factory).beacon();
    }

    /// @dev Deploys PaymentGateway via UUPS proxy. Caller must call factory.setPaymentGateway(gateway) after.
    function _deployPaymentGateway(
        address initialOwner,
        address bridgeAddress,
        address factoryAddress
    ) internal returns (PaymentGatewayResult memory r) {
        _requireUnsafeUpgradeApproval();
        bytes memory initializerData = abi.encodeCall(PaymentGateway.initialize, (initialOwner, bridgeAddress, factoryAddress));
        PaymentGateway impl = new PaymentGateway();
        r.gatewayImpl = address(impl);
        r.gateway = UnsafeUpgrades.deployUUPSProxy(r.gatewayImpl, initializerData);
    }

    /// @dev Deploys UniversalTokenFactory via UUPS proxy. Uses UnsafeUpgrades because artifact is unlinked (UniversalTokenSDK). Caller must be in broadcast.
    function _deployUniversalTokenFactory(address initialOwner) internal returns (address factoryProxy, address factoryImpl) {
        _requireUnsafeUpgradeApproval();
        UniversalTokenFactory impl = new UniversalTokenFactory();
        factoryImpl = address(impl);
        bytes memory initializerData = abi.encodeCall(UniversalTokenFactory.initialize, (initialOwner));
        factoryProxy = UnsafeUpgrades.deployUUPSProxy(factoryImpl, initializerData);
    }

    /// @dev Deploys a mock ERC20. Caller must be in broadcast.
    function _deployMockERC20(string memory name, string memory symbol, uint256 supply, address recipient) internal returns (address token) {
        MockERC20Token t = new MockERC20Token(name, symbol, supply, recipient);
        return address(t);
    }
}
