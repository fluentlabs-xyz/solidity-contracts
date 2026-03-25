// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";

import {DeployL2Bridge} from "./DeployL2Bridge.s.sol";
import {DeployUniversalFactory} from "./DeployUniversalFactory.s.sol";
import {DeployERC20Gateway} from "./DeployERC20Gateway.s.sol";
import {DeployNativeGateway} from "./DeployNativeGateway.s.sol";
import {L1BlockOracle} from "../../contracts/oracles/L1BlockOracle.sol";
import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";

/// @notice L2 orchestrator: deploys full stack in dependency order.
/// @dev Reads config from scripts/config/<NETWORK>.json.
contract DeployL2 is DeployL2Bridge, DeployUniversalFactory, DeployERC20Gateway, DeployNativeGateway {
    using stdJson for string;

    address private constant UNIVERSAL_RUNTIME = 0x0000000000000000000000000000000000520008;

    function run() external override(DeployL2Bridge, DeployUniversalFactory, DeployERC20Gateway, DeployNativeGateway) {
        string memory network = vm.envOr("NETWORK", string("testnet/l2"));
        string memory json = _readConfig(network);
        string memory outputPath = vm.envOr("OUTPUT_PATH", string.concat("deployments/", network, ".json"));

        address initialOwner = vm.envOr("INITIAL_OWNER", json.readAddress(".roles.initialOwner"));
        require(initialOwner != address(0), "INITIAL_OWNER required");
        address adminRole = vm.envOr("ADMIN_ROLE", json.readAddress(".roles.admin"));
        address pauserRole = vm.envOr("PAUSER_ROLE", json.readAddress(".roles.pauser"));
        address relayerRole = vm.envOr("RELAYER_ROLE", json.readAddress(".roles.relayer"));
        uint256 receiveMessageDeadline = vm.envOr("RECEIVE_MSG_DEADLINE", json.readUint(".bridge.receiveMessageDeadline"));

        vm.startBroadcast();

        // 1. L1BlockOracle (plain contract)
        address l1BlockOracle = address(new L1BlockOracle(relayerRole));

        // 2. Bridge
        L2BridgeResult memory bridge = _deployL2Bridge(
            adminRole,
            pauserRole,
            relayerRole,
            address(0x1),
            l1BlockOracle,
            receiveMessageDeadline,
            address(0)
        );

        // 3. UniversalTokenFactory + ERC20Gateway
        UniversalFactoryResult memory factory = _deployUniversalFactory(initialOwner);
        ERC20GatewayResult memory erc20Gw = _deployERC20Gateway(initialOwner, bridge.proxy, factory.factory);
        UniversalTokenFactory(factory.factory).setPaymentGateway(erc20Gw.gateway);

        // 4. NativeGateway
        NativeGatewayResult memory nativeGw = _deployNativeGateway(initialOwner, bridge.proxy);

        vm.stopBroadcast();

        _writeL2Manifest(outputPath, l1BlockOracle, bridge, factory, erc20Gw, nativeGw);
    }

    function _writeL2Manifest(
        string memory outputPath,
        address l1BlockOracle,
        L2BridgeResult memory bridge,
        UniversalFactoryResult memory factory,
        ERC20GatewayResult memory erc20Gw,
        NativeGatewayResult memory nativeGw
    ) internal {
        string memory out = vm.serializeUint("deployment", "chainId", block.chainid);
        out = vm.serializeAddress("deployment", "l1_block_oracle", l1BlockOracle);
        out = vm.serializeAddress("deployment", "bridge", bridge.proxy);
        out = vm.serializeAddress("deployment", "bridge_impl", bridge.impl);
        out = vm.serializeAddress("deployment", "factory", factory.factory);
        out = vm.serializeAddress("deployment", "factory_impl", factory.factoryImpl);
        out = vm.serializeAddress("deployment", "pegged_impl", UNIVERSAL_RUNTIME);
        out = vm.serializeAddress("deployment", "erc20_gateway", erc20Gw.gateway);
        out = vm.serializeAddress("deployment", "erc20_gateway_impl", erc20Gw.gatewayImpl);
        out = vm.serializeAddress("deployment", "native_gateway", nativeGw.gateway);
        out = vm.serializeAddress("deployment", "native_gateway_impl", nativeGw.gatewayImpl);
        vm.writeJson(out, outputPath);
    }
}
