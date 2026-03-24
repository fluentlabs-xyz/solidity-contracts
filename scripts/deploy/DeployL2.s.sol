// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";

import {DeployLib} from "./components/DeployLib.s.sol";
import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";
import {L1BlockOracle} from "../../contracts/oracles/L1BlockOracle.sol";
import {NativeGateway} from "../../contracts/gateways/NativeGateway.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/**
 * @notice L2 deploy orchestrator: L1BlockOracle + Bridge + Factory + Gateways.
 * @dev Reads chain config from scripts/input/<NETWORK>.json. Env vars override JSON values.
 *      Requires ALLOW_UNSAFE_UPGRADES=true (for UniversalTokenFactory).
 */
contract DeployL2 is DeployLib {
    using stdJson for string;

    address private constant UNIVERSAL_RUNTIME = 0x0000000000000000000000000000000000520008;

    struct Deployment {
        address l1BlockOracle;
        address bridge;
        address bridgeImpl;
        address peggedImpl;
        address factoryImpl;
        address factory;
        address factoryBeacon;
        address erc20GatewayImpl;
        address erc20Gateway;
        address nativeGatewayImpl;
        address nativeGateway;
    }

    function run() external {
        // Phase 1: Config
        string memory network = vm.envOr("NETWORK", string("testnet/l2"));
        string memory json = _readConfig(network);
        string memory outputPath = vm.envOr("OUTPUT_PATH", string("deployments/fluent_dev.json"));

        address initialOwner = vm.envOr("INITIAL_OWNER", json.readAddress(".roles.initialOwner"));
        require(initialOwner != address(0), "INITIAL_OWNER required");

        address adminRole = vm.envOr("ADMIN_ROLE", json.readAddress(".roles.admin"));
        address pauserRole = vm.envOr("PAUSER_ROLE", json.readAddress(".roles.pauser"));
        address relayerRole = vm.envOr("RELAYER_ROLE", json.readAddress(".roles.relayer"));
        uint256 receiveMessageDeadline = vm.envOr("RECEIVE_MSG_DEADLINE", json.readUint(".bridge.receiveMessageDeadline"));
        require(receiveMessageDeadline != 0, "RECEIVE_MSG_DEADLINE required for L2 deploy");
        address otherBridgePlaceholder = vm.envOr("OTHER_BRIDGE_PLACEHOLDER", address(0x1));

        Deployment memory d;

        // Phase 2: Deploy
        vm.startBroadcast();

        // 1. L1BlockOracle (plain contract, prerequisite for bridge)
        d.l1BlockOracle = address(new L1BlockOracle(relayerRole));

        // 2. Bridge (uses oracle from step 1)
        (d.bridge, d.bridgeImpl) = _deployFluentBridge(
            adminRole, pauserRole, relayerRole, receiveMessageDeadline,
            otherBridgePlaceholder, d.l1BlockOracle, address(0)
        );

        // 3. UniversalTokenFactory + ERC20Gateway
        (d.factory, d.factoryImpl) = _deployUniversalTokenFactory(initialOwner);
        {
            ERC20GatewayResult memory gatewayResult = _deployERC20Gateway(initialOwner, d.bridge, d.factory);
            d.erc20GatewayImpl = gatewayResult.gatewayImpl;
            d.erc20Gateway = gatewayResult.gateway;
        }
        UniversalTokenFactory(d.factory).setPaymentGateway(d.erc20Gateway);
        d.peggedImpl = UNIVERSAL_RUNTIME;
        d.factoryBeacon = address(0);

        // 4. NativeGateway
        d.nativeGateway = Upgrades.deployUUPSProxy(
            "NativeGateway.sol:NativeGateway",
            abi.encodeCall(NativeGateway.initialize, (initialOwner, d.bridge))
        );
        d.nativeGatewayImpl = Upgrades.getImplementationAddress(d.nativeGateway);

        vm.stopBroadcast();

        // Phase 3: Artifacts
        if (bytes(outputPath).length != 0) {
            _writeOutput(outputPath, d);
        }
    }

    function _writeOutput(string memory outputPath, Deployment memory d) internal {
        string memory out = vm.serializeAddress("deployment", "l1_block_oracle", d.l1BlockOracle);
        out = vm.serializeAddress("deployment", "bridge", d.bridge);
        out = vm.serializeAddress("deployment", "bridge_impl", d.bridgeImpl);
        out = vm.serializeAddress("deployment", "pegged_impl", d.peggedImpl);
        out = vm.serializeAddress("deployment", "factory_impl", d.factoryImpl);
        out = vm.serializeAddress("deployment", "factory", d.factory);
        out = vm.serializeAddress("deployment", "factory_beacon", d.factoryBeacon);
        out = vm.serializeAddress("deployment", "erc20_gateway_impl", d.erc20GatewayImpl);
        out = vm.serializeAddress("deployment", "erc20_gateway", d.erc20Gateway);
        out = vm.serializeAddress("deployment", "native_gateway_impl", d.nativeGatewayImpl);
        out = vm.serializeAddress("deployment", "native_gateway", d.nativeGateway);
        vm.writeJson(out, outputPath);
    }
}
