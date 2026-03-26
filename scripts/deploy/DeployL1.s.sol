// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";

import {DeployRollup} from "./DeployRollup.s.sol";
import {DeployL1Bridge} from "./DeployL1Bridge.s.sol";
import {DeployERC20Factory} from "./DeployERC20Factory.s.sol";
import {DeployERC20Gateway} from "./DeployERC20Gateway.s.sol";
import {DeployNativeGateway} from "./DeployNativeGateway.s.sol";
import {NitroVerifier} from "../../contracts/verifier/NitroVerifier.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";
import {InitConfiguration} from "../../contracts/interfaces/IRollupTypes.sol";
import {MockERC20Token} from "../../test/mocks/MockERC20.sol";

/// @notice L1 orchestrator: deploys full stack in dependency order.
/// @dev Reads config from scripts/config/<NETWORK>.json.
///      Handles the bridge↔rollup circular dependency: deploys rollup with placeholder bridge,
///      then bridge with real rollup, then calls Rollup.setBridge().
contract DeployL1 is DeployRollup, DeployL1Bridge, DeployERC20Factory, DeployERC20Gateway, DeployNativeGateway {
    using stdJson for string;

    function run() external override(DeployRollup, DeployL1Bridge, DeployERC20Factory, DeployERC20Gateway, DeployNativeGateway) {
        string memory network = vm.envOr("NETWORK", string("testnet/l1"));
        string memory json = _readConfig(network);
        string memory outputPath = vm.envOr("OUTPUT_PATH", string.concat("deployments/", network, ".json"));

        address initialOwner = vm.envOr("INITIAL_OWNER", json.readAddress(".roles.initialOwner"));
        require(initialOwner != address(0), "INITIAL_OWNER required");
        address adminRole = vm.envOr("ADMIN_ROLE", json.readAddress(".roles.admin"));
        address pauserRole = vm.envOr("PAUSER_ROLE", json.readAddress(".roles.pauser"));
        address relayerRole = vm.envOr("RELAYER_ROLE", json.readAddress(".roles.relayer"));

        vm.startBroadcast();

        // 1. NitroVerifier (plain contract)
        address nitroVerifier = address(new NitroVerifier(vm.envOr("SP1_VERIFIER", json.readAddress(".rollup.sp1Verifier")), adminRole));

        // 2. Rollup (bridge=placeholder, resolved in step 4)
        InitConfiguration memory rollupParams = _readRollupParams(json, adminRole, nitroVerifier);
        rollupParams.bridge = address(0x1);
        RollupResult memory rollup = _deployRollup(rollupParams);

        // 3. Bridge (with real rollup)
        L1BridgeResult memory bridge = _deployL1Bridge(adminRole, pauserRole, relayerRole, address(0x1), rollup.proxy);

        // 4. Close circular dependency
        Rollup(rollup.proxy).setBridge(bridge.proxy);

        // 5. ERC20 factory + gateway
        ERC20FactoryResult memory factory = _deployERC20Factory(initialOwner);
        ERC20GatewayResult memory erc20Gw = _deployERC20Gateway(initialOwner, bridge.proxy, factory.factory);
        ERC20TokenFactory(factory.factory).setPaymentGateway(erc20Gw.gateway);

        // 6. NativeGateway
        NativeGatewayResult memory nativeGw = _deployNativeGateway(initialOwner, bridge.proxy);

        // 7. Mock token (testnet only)
        address mockToken = _deployMock(initialOwner);

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
