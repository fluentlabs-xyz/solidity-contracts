// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, stdJson} from "forge-std/Script.sol";

import {Upgrades, UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {L1FluentBridge} from "../../../contracts/bridge/L1/L1FluentBridge.sol";
import {L2FluentBridge} from "../../../contracts/bridge/L2/L2FluentBridge.sol";
import {FluentBridgeStorageLayout} from "../../../contracts/bridge/FluentBridgeStorageLayout.sol";
import {InitConfiguration} from "../../../contracts/interfaces/IRollupTypes.sol";
import {Rollup} from "../../../contracts/rollup/Rollup.sol";
import {L1GasOracle} from "../../../contracts/oracles/L1GasOracle.sol";
import {ERC20Gateway} from "../../../contracts/gateways/ERC20Gateway.sol";
import {ERC20TokenFactory} from "../../../contracts/factories/ERC20TokenFactory.sol";
import {ERC20PeggedToken} from "../../../contracts/tokens/ERC20PeggedToken.sol";
import {UniversalTokenFactory} from "../../../contracts/factories/UniversalTokenFactory.sol";
import {MockERC20Token} from "../../../test/mocks/MockERC20.sol";

/**
 * @notice Shared deployment logic for L1/L2 stacks. No broadcast; caller must vm.startBroadcast/stopBroadcast.
 * @dev Uses the safe {Upgrades.deployUUPSProxy} API with full storage layout validation for all
 *      proxy deployments. The only exception is {_deployUniversalTokenFactory} which uses
 *      {UnsafeUpgrades} because the UniversalTokenSDK library is unlinked and cannot be resolved
 *      by the OZ upgrade validator. That path requires ALLOW_UNSAFE_UPGRADES=true.
 */
abstract contract DeployLib is Script {
    using stdJson for string;

    struct ERC20FactoryResult {
        address factory;
        address factoryImpl;
        address factoryBeacon;
        address peggedImpl;
    }

    struct ERC20GatewayResult {
        address gateway;
        address gatewayImpl;
    }

    /// @dev Reads a chain config JSON from scripts/input/<network>.json.
    /// @dev Reads a chain config JSON from scripts/config/<network>.json.
    ///      Network can include subdirectories, e.g. "testnet/l1" → scripts/config/testnet/l1.json.
    function _readConfig(string memory network) internal view returns (string memory) {
        string memory path = string.concat("scripts/config/", network, ".json");
        return vm.readFile(path);
    }

    /// @dev Artifact names for the safe Upgrades API.
    string constant L1_FLUENT_BRIDGE = "L1FluentBridge.sol:L1FluentBridge";
    string constant L2_FLUENT_BRIDGE = "L2FluentBridge.sol:L2FluentBridge";
    string constant ERC20_GATEWAY = "ERC20Gateway.sol:ERC20Gateway";
    string constant ROLLUP = "Rollup.sol:Rollup";
    string constant ERC20_TOKEN_FACTORY = "ERC20TokenFactory.sol:ERC20TokenFactory";

    /// @dev Deploys FluentBridge via UUPS proxy with full OZ upgrade validation.
    ///      For L2 (`receiveMessageDeadline != 0`), if `l1GasOracle == address(0)` a new {L1GasOracle} is deployed
    ///      with `relayerRole` as submitter; if `feeTreasury == address(0)` it defaults to `adminRole`.
    function _deployFluentBridge(
        address adminRole,
        address pauserRole,
        address relayerRole,
        uint256 receiveMessageDeadline,
        address otherBridgePlaceholder,
        address l1BlockOracle,
        address rollup
    ) internal returns (address bridgeProxy, address bridgeImpl) {
        return
            _deployFluentBridge(
                adminRole,
                pauserRole,
                relayerRole,
                receiveMessageDeadline,
                otherBridgePlaceholder,
                l1BlockOracle,
                address(0),
                uint256(0),
                uint256(0),
                uint256(0),
                address(0),
                rollup
            );
    }

    /// @dev Full L2 init: `l1GasOracle`, `overheadGasPrice`, `scalarGasPrice`, `feeTreasury` (use zeros to mirror the 7-arg overload defaults).
    function _deployFluentBridge(
        address adminRole,
        address pauserRole,
        address relayerRole,
        uint256 receiveMessageDeadline,
        address otherBridgePlaceholder,
        address l1BlockOracle,
        address l1GasOracle,
        uint256 overheadGasPrice,
        uint256 scalarGasPrice,
        uint256 l1GasLimit,
        address feeTreasury,
        address rollup
    ) internal returns (address bridgeProxy, address bridgeImpl) {
        FluentBridgeStorageLayout.InitConfiguration memory params = FluentBridgeStorageLayout.InitConfiguration({
            adminRole: adminRole,
            pauserRole: pauserRole,
            relayerRole: relayerRole,
            otherBridge: otherBridgePlaceholder
        });
        bytes memory initData = abi.encode(params);

        if (receiveMessageDeadline == 0) {
            require(rollup != address(0), "ROLLUP required when RECEIVE_MSG_DEADLINE == 0 (L1 deploy)");
            bytes memory initializerData = abi.encodeCall(L1FluentBridge.initialize, (initData, rollup));
            bridgeProxy = Upgrades.deployUUPSProxy(L1_FLUENT_BRIDGE, initializerData);
            bridgeImpl = Upgrades.getImplementationAddress(bridgeProxy);
        } else {
            require(l1BlockOracle != address(0), "L1_BLOCK_ORACLE required when RECEIVE_MSG_DEADLINE != 0");
            address gasOracleAddr = l1GasOracle;
            if (gasOracleAddr == address(0)) {
                gasOracleAddr = address(new L1GasOracle(relayerRole));
            }
            address treasury = feeTreasury == address(0) ? adminRole : feeTreasury;
            bytes memory initializerData = abi.encodeCall(
                L2FluentBridge.initialize,
                (initData, receiveMessageDeadline, l1BlockOracle, gasOracleAddr, overheadGasPrice, scalarGasPrice, l1GasLimit, treasury)
            );
            bridgeProxy = Upgrades.deployUUPSProxy(L2_FLUENT_BRIDGE, initializerData);
            bridgeImpl = Upgrades.getImplementationAddress(bridgeProxy);
        }
    }

    /// @dev Deploys ERC20 factory stack (L1): pegged impl, then factory UUPS proxy with full OZ upgrade validation.
    function _deployERC20TokenFactory(address initialOwner) internal returns (ERC20FactoryResult memory r) {
        ERC20PeggedToken peggedImpl = new ERC20PeggedToken();
        r.peggedImpl = address(peggedImpl);
        bytes memory initializerData = abi.encodeCall(ERC20TokenFactory.initialize, (initialOwner, address(peggedImpl)));
        r.factory = Upgrades.deployUUPSProxy(ERC20_TOKEN_FACTORY, initializerData);
        r.factoryImpl = Upgrades.getImplementationAddress(r.factory);
        r.factoryBeacon = ERC20TokenFactory(r.factory).beacon();
    }

    /// @dev Deploys ERC20Gateway via UUPS proxy with full OZ upgrade validation.
    function _deployERC20Gateway(
        address initialOwner,
        address bridgeAddress,
        address factoryAddress
    ) internal returns (ERC20GatewayResult memory r) {
        bytes memory initializerData = abi.encodeCall(ERC20Gateway.initialize, (initialOwner, bridgeAddress, factoryAddress));
        r.gateway = Upgrades.deployUUPSProxy(ERC20_GATEWAY, initializerData);
        r.gatewayImpl = Upgrades.getImplementationAddress(r.gateway);
    }

    /// @dev Deploys UniversalTokenFactory via UUPS proxy. Uses {UnsafeUpgrades} because the
    ///      UniversalTokenSDK library is unlinked and the safe Upgrades API cannot resolve
    ///      the artifact. This is the ONLY deploy helper that requires ALLOW_UNSAFE_UPGRADES=true.
    function _deployUniversalTokenFactory(address initialOwner) internal returns (address factoryProxy, address factoryImpl) {
        require(vm.envOr("ALLOW_UNSAFE_UPGRADES", false), "ALLOW_UNSAFE_UPGRADES=true required (UniversalTokenFactory has unlinked libs)");
        UniversalTokenFactory impl = new UniversalTokenFactory();
        factoryImpl = address(impl);
        bytes memory initializerData = abi.encodeCall(UniversalTokenFactory.initialize, (initialOwner));
        factoryProxy = UnsafeUpgrades.deployUUPSProxy(factoryImpl, initializerData);
    }

    /// @dev Deploys Rollup via UUPS proxy with full OZ upgrade validation.
    function _deployRollup(InitConfiguration memory params) internal returns (address rollupProxy, address rollupImpl) {
        bytes memory initData = abi.encodeCall(Rollup.initialize, (abi.encode(params)));
        rollupProxy = Upgrades.deployUUPSProxy(ROLLUP, initData);
        rollupImpl = Upgrades.getImplementationAddress(rollupProxy);
    }

    /// @dev Deploys a mock ERC20. Caller must be in broadcast.
    function _deployMockERC20(string memory name, string memory symbol, uint256 supply, address recipient) internal returns (address token) {
        MockERC20Token t = new MockERC20Token(name, symbol, supply, recipient);
        return address(t);
    }
}
