// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";

import {DeployRollup} from "./DeployRollup.s.sol";
import {DeployL1Bridge} from "./DeployL1Bridge.s.sol";
import {DeployERC20Factory} from "./DeployERC20Factory.s.sol";
import {DeployERC20Gateway} from "./DeployERC20Gateway.s.sol";
import {DeployNativeGateway} from "./DeployNativeGateway.s.sol";
import {NitroVerifier} from "../../contracts/verifier/NitroVerifier.sol";
import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";
import {InitConfiguration} from "../../contracts/interfaces/IRollupTypes.sol";
import {MockERC20Token} from "../../test/mocks/MockERC20.sol";

/// @notice L1 orchestrator: deploys full stack with deterministic nonce ordering.
/// @dev Three-phase deployment ensures proxy addresses match L2 counterparts.
///      Phase 1 (nonce 0-8): matched contracts — bridge, factory prereq, factory, gateways.
///      Phase 2 (nonce 9+): L1-specific — NitroVerifier, Rollup, MockToken.
///      Phase 3: configure — Bridge.setRollup(), Factory.setPaymentGateway().
contract DeployL1 is DeployRollup, DeployL1Bridge, DeployERC20Factory, DeployERC20Gateway, DeployNativeGateway {
    using stdJson for string;

    function run() external override(DeployRollup, DeployL1Bridge, DeployERC20Factory, DeployERC20Gateway, DeployNativeGateway) {
        string memory network = vm.envOr("NETWORK", string("testnet/l1"));
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
        require(receiveMessageDeadline > 0, "RECEIVE_MSG_DEADLINE required");

        vm.startBroadcast();
        require(vm.getNonce(msg.sender) == 0, "deployer nonce must be 0 for deterministic addresses");

        // ── Phase 1: Matched contracts (nonce 0–8) ──
        // Bridge with rollup placeholder (nonce 0: impl, nonce 1: proxy)
        L1BridgeResult memory bridge =
            _deployL1Bridge(adminRole, pauserRole, relayerRole, address(0x1), address(0x1), receiveMessageDeadline);

        // Factory prerequisite: ERC20PeggedToken impl (nonce 2)
        // Factory impl (nonce 3), Factory proxy (nonce 4)
        ERC20FactoryResult memory factory = _deployERC20Factory(initialOwner);

        // ERC20Gateway (nonce 5: impl, nonce 6: proxy)
        ERC20GatewayResult memory erc20Gw = _deployERC20Gateway(initialOwner, bridge.proxy, factory.factory);

        // NativeGateway (nonce 7: impl, nonce 8: proxy)
        NativeGatewayResult memory nativeGw = _deployNativeGateway(initialOwner, bridge.proxy);

        // ── Phase 2: L1-specific contracts (nonce 9+) ──
        // NitroVerifier (nonce 9)
        address nitroVerifier = address(new NitroVerifier(vm.envOr("SP1_VERIFIER", json.readAddress(".rollup.sp1Verifier")), adminRole));

        // Rollup with real bridge address (nonce 10: impl, nonce 11: proxy)
        InitConfiguration memory rollupParams = _readRollupParams(json, adminRole, nitroVerifier);
        rollupParams.bridge = bridge.proxy;
        RollupResult memory rollup = _deployRollup(rollupParams);

        // MockERC20Token — testnet only (nonce 12)
        address mockToken = _deployMock(initialOwner);

        // ── Phase 3: Configure ──
        // Close bridge↔rollup circular dependency (nonce 13)
        L1FluentBridge(payable(bridge.proxy)).setRollup(rollup.proxy);
        // Wire factory payment gateway (nonce 14)
        ERC20TokenFactory(factory.factory).setPaymentGateway(erc20Gw.gateway);

        vm.stopBroadcast();

        _writeL1Manifest(outputPath, nitroVerifier, rollup, bridge, factory, erc20Gw, nativeGw, mockToken);
    }

    function _deployMock(address initialOwner) internal returns (address) {
        return
            address(
                new MockERC20Token(
                    vm.envOr("MOCK_ERC20_NAME", string("Mock Deposit Token")),
                    vm.envOr("MOCK_ERC20_SYMBOL", string("MDT")),
                    vm.envOr("MOCK_ERC20_SUPPLY", uint256(1_000_000 ether)),
                    vm.envOr("MOCK_ERC20_RECIPIENT", initialOwner)
                )
            );
    }

    function _writeL1Manifest(
        string memory outputPath,
        address nitroVerifier,
        RollupResult memory rollup,
        L1BridgeResult memory bridge,
        ERC20FactoryResult memory factory,
        ERC20GatewayResult memory erc20Gw,
        NativeGatewayResult memory nativeGw,
        address mockToken
    ) internal {
        string memory out = vm.serializeUint("deployment", "chainId", block.chainid);
        out = vm.serializeAddress("deployment", "nitro_verifier", nitroVerifier);
        out = vm.serializeAddress("deployment", "rollup", rollup.proxy);
        out = vm.serializeAddress("deployment", "rollup_impl", rollup.impl);
        out = vm.serializeAddress("deployment", "bridge", bridge.proxy);
        out = vm.serializeAddress("deployment", "bridge_impl", bridge.impl);
        out = vm.serializeAddress("deployment", "factory", factory.factory);
        out = vm.serializeAddress("deployment", "factory_impl", factory.factoryImpl);
        out = vm.serializeAddress("deployment", "factory_beacon", factory.factoryBeacon);
        out = vm.serializeAddress("deployment", "pegged_impl", factory.peggedImpl);
        out = vm.serializeAddress("deployment", "erc20_gateway", erc20Gw.gateway);
        out = vm.serializeAddress("deployment", "erc20_gateway_impl", erc20Gw.gatewayImpl);
        out = vm.serializeAddress("deployment", "native_gateway", nativeGw.gateway);
        out = vm.serializeAddress("deployment", "native_gateway_impl", nativeGw.gatewayImpl);
        out = vm.serializeAddress("deployment", "mock_token", mockToken);
        vm.writeJson(out, outputPath);
    }
}
