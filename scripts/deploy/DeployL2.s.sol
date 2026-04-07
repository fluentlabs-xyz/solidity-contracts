// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";

import {DeployL2Bridge} from "./DeployL2Bridge.s.sol";
import {DeployUniversalFactory} from "./DeployUniversalFactory.s.sol";
import {DeployERC20Gateway} from "./DeployERC20Gateway.s.sol";
import {DeployNativeGateway} from "./DeployNativeGateway.s.sol";
import {L1BlockOracle} from "../../contracts/oracles/L1BlockOracle.sol";
import {L1GasOracle} from "../../contracts/oracles/L1GasOracle.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";

/// @notice L2 orchestrator: deploys full stack with deterministic nonce ordering.
/// @dev Three-phase deployment ensures proxy addresses match L1 counterparts.
///      Phase 1 (nonce 0-8): matched contracts — bridge (with placeholders), oracle alignment slot, factory, gateways.
///      Phase 2 (nonce 9): L2-specific — L1GasOracle.
///      Phase 3 (nonce 10-14): configure — oracle wiring, gas config, fee treasury, payment gateway.
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
        require(adminRole != address(0), "ADMIN_ROLE required");
        address pauserRole = vm.envOr("PAUSER_ROLE", json.readAddress(".roles.pauser"));
        require(pauserRole != address(0), "PAUSER_ROLE required");
        address relayerRole = vm.envOr("RELAYER_ROLE", json.readAddress(".roles.relayer"));
        require(relayerRole != address(0), "RELAYER_ROLE required");
        uint256 receiveMessageDeadline = vm.envOr("RECEIVE_MSG_DEADLINE", json.readUint(".bridge.receiveMessageDeadline"));

        vm.startBroadcast();
        require(vm.getNonce(msg.sender) == 0, "deployer nonce must be 0 for deterministic addresses");

        // ── Phase 1: Matched contracts (nonce 0–8) ──
        // Bridge with placeholders (nonce 0: impl, nonce 1: proxy)
        L2BridgeResult memory bridge = _deployL2Bridge(
            adminRole,
            pauserRole,
            relayerRole,
            address(0x1),
            address(0x1),
            receiveMessageDeadline,
            address(0x1),
            adminRole
        );

        // L1BlockOracle — nonce alignment slot (nonce 2)
        address l1BlockOracle = address(new L1BlockOracle(relayerRole));

        // UniversalTokenFactory (nonce 3: impl, nonce 4: proxy)
        UniversalFactoryResult memory factory = _deployUniversalFactory(initialOwner);

        // ERC20Gateway (nonce 5: impl, nonce 6: proxy)
        ERC20GatewayResult memory erc20Gw = _deployERC20Gateway(initialOwner, bridge.proxy, factory.factory);

        // NativeGateway (nonce 7: impl, nonce 8: proxy)
        NativeGatewayResult memory nativeGw = _deployNativeGateway(initialOwner, bridge.proxy);

        // ── Phase 2: L2-specific contracts (nonce 9) ──
        address gasOracle = address(new L1GasOracle(relayerRole));

        // ── Phase 3: Configure (nonce 10–14) ──
        L2FluentBridge l2Bridge = L2FluentBridge(payable(bridge.proxy));
        l2Bridge.setL1BlockOracle(l1BlockOracle);
        l2Bridge.setL1GasPriceOracle(gasOracle);
        l2Bridge.setGasPriceConfig(
            json.readUint(".bridge.gasPriceConfig.overheadGasPrice"),
            json.readUint(".bridge.gasPriceConfig.scalarGasPrice"),
            json.readUint(".bridge.gasPriceConfig.l1GasLimit")
        );
        l2Bridge.setFeeTreasury(vm.envOr("FEE_TREASURY", json.readAddress(".bridge.feeTreasury")));
        UniversalTokenFactory(factory.factory).setPaymentGateway(erc20Gw.gateway);

        vm.stopBroadcast();

        _writeL2Manifest(outputPath, l1BlockOracle, gasOracle, bridge, factory, erc20Gw, nativeGw);
    }

    function _writeL2Manifest(
        string memory outputPath,
        address l1BlockOracle,
        address gasOracle,
        L2BridgeResult memory bridge,
        UniversalFactoryResult memory factory,
        ERC20GatewayResult memory erc20Gw,
        NativeGatewayResult memory nativeGw
    ) internal {
        string memory out = vm.serializeUint("deployment", "chainId", block.chainid);
        out = vm.serializeAddress("deployment", "l1_block_oracle", l1BlockOracle);
        out = vm.serializeAddress("deployment", "l1_gas_oracle", gasOracle);
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
