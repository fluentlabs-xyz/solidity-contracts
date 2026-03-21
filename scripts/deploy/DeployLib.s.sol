// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";

import {Upgrades, UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";

import {FluentBridge} from "../../contracts/bridge/FluentBridge.sol";
import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {FluentBridgeStorageLayout} from "../../contracts/bridge/FluentBridgeStorageLayout.sol";
import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";
import {MockERC20Token} from "../../test/mocks/MockERC20.sol";

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
    string constant ERC20_GATEWAY = "ERC20Gateway.sol:ERC20Gateway";
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
        address l1BlockOracle,
        address rollup
    ) internal returns (address bridgeProxy, address bridgeImpl) {
        // NOTE: This repo uses chain-specific bridge implementations (L1FluentBridge / L2FluentBridge).
        // We deploy the appropriate implementation based on whether a receive deadline is configured.
        FluentBridgeStorageLayout.InitConfiguration memory params = FluentBridgeStorageLayout.InitConfiguration({
            adminRole: adminRole,
            pauserRole: pauserRole,
            relayerRole: relayerRole,
            otherBridge: otherBridgePlaceholder
        });
        bytes memory initData = abi.encode(params);

        _requireUnsafeUpgradeApproval();
        if (receiveMessageDeadline == 0) {
            require(rollup != address(0), "ROLLUP required when RECEIVE_MSG_DEADLINE == 0 (L1 deploy)");
            L1FluentBridge impl = new L1FluentBridge();
            bridgeImpl = address(impl);
            bytes memory initializerData = abi.encodeCall(L1FluentBridge.initialize, (initData, rollup));
            bridgeProxy = UnsafeUpgrades.deployUUPSProxy(bridgeImpl, initializerData);
        } else {
            require(l1BlockOracle != address(0), "L1_BLOCK_ORACLE required when RECEIVE_MSG_DEADLINE != 0");
            L2FluentBridge impl = new L2FluentBridge();
            bridgeImpl = address(impl);
            bytes memory initializerData = abi.encodeCall(L2FluentBridge.initialize, (initData, receiveMessageDeadline, l1BlockOracle));
            bridgeProxy = UnsafeUpgrades.deployUUPSProxy(bridgeImpl, initializerData);
        }
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

    /// @dev Deploys ERC20Gateway via UUPS proxy. Caller must call factory.setPaymentGateway(gateway) after.
    function _deployPaymentGateway(
        address initialOwner,
        address bridgeAddress,
        address factoryAddress
    ) internal returns (PaymentGatewayResult memory r) {
        _requireUnsafeUpgradeApproval();
        bytes memory initializerData = abi.encodeCall(ERC20Gateway.initialize, (initialOwner, bridgeAddress, factoryAddress));
        ERC20Gateway impl = new ERC20Gateway();
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
