// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";

import {DeployLib} from "./components/DeployLib.s.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";
import {NitroVerifier} from "../../contracts/verifier/NitroVerifier.sol";
import {NativeGateway} from "../../contracts/gateways/NativeGateway.sol";
import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {InitConfiguration} from "../../contracts/interfaces/IRollupTypes.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/**
 * @notice L1 deploy orchestrator: NitroVerifier + Bridge + Rollup + Factories + Gateways.
 * @dev Reads chain config from scripts/input/<NETWORK>.json. Env vars override JSON values.
 *      Handles the bridge↔rollup circular dependency: deploys bridge with rollup=0x0,
 *      then deploys rollup with the bridge address, then calls bridge.setRollup().
 */
contract DeployL1 is DeployLib {
    using stdJson for string;

    struct Deployment {
        address nitroVerifier;
        address bridge;
        address bridgeImpl;
        address rollup;
        address rollupImpl;
        address peggedImpl;
        address factoryImpl;
        address factory;
        address factoryBeacon;
        address erc20GatewayImpl;
        address erc20Gateway;
        address nativeGatewayImpl;
        address nativeGateway;
        address mockToken;
    }

    function run() external {
        // Phase 1: Config
        string memory network = vm.envOr("NETWORK", string("testnet/l1"));
        string memory json = _readConfig(network);
        string memory outputPath = vm.envOr("OUTPUT_PATH", string("deployments/sepolia.json"));

        address initialOwner = vm.envOr("INITIAL_OWNER", json.readAddress(".roles.initialOwner"));
        require(initialOwner != address(0), "INITIAL_OWNER required");

        address adminRole = vm.envOr("ADMIN_ROLE", json.readAddress(".roles.admin"));
        address pauserRole = vm.envOr("PAUSER_ROLE", json.readAddress(".roles.pauser"));
        address relayerRole = vm.envOr("RELAYER_ROLE", json.readAddress(".roles.relayer"));
        address otherBridgePlaceholder = vm.envOr("OTHER_BRIDGE_PLACEHOLDER", address(0x1));

        Deployment memory d;

        // Phase 2: Deploy
        vm.startBroadcast();

        // 1. NitroVerifier (plain contract, no proxy)
        d.nitroVerifier = address(new NitroVerifier(
            vm.envOr("SP1_VERIFIER", json.readAddress(".rollup.sp1Verifier")),
            adminRole
        ));

        // 2. Bridge (rollup=0x0 initially — resolved in step 4)
        (d.bridge, d.bridgeImpl) = _deployFluentBridge(
            adminRole, pauserRole, relayerRole, 0, otherBridgePlaceholder, address(0), address(0)
        );

        // 3. Rollup (needs bridge address from step 2)
        {
            InitConfiguration memory rollupParams;
            rollupParams.admin = adminRole;
            rollupParams.emergency = vm.envOr("ROLLUP_EMERGENCY", json.readAddress(".rollup.emergency"));
            rollupParams.sequencer = vm.envOr("ROLLUP_SEQUENCER", json.readAddress(".rollup.sequencer"));
            rollupParams.challenger = vm.envOr("ROLLUP_CHALLENGER", json.readAddress(".rollup.challenger"));
            rollupParams.prover = vm.envOr("ROLLUP_PROVER", json.readAddress(".rollup.prover"));
            rollupParams.preconfirmationRole = vm.envOr("ROLLUP_PRECONFIRMATION_ROLE", json.readAddress(".rollup.preconfirmation"));
            rollupParams.nitroVerifier = d.nitroVerifier;
            rollupParams.sp1Verifier = vm.envOr("SP1_VERIFIER", json.readAddress(".rollup.sp1Verifier"));
            rollupParams.bridge = d.bridge;
            rollupParams.programVKey = vm.envOr("ROLLUP_PROGRAM_VKEY", json.readBytes32(".rollup.programVKey"));
            rollupParams.genesisHash = vm.envOr("ROLLUP_GENESIS_HASH", json.readBytes32(".rollup.genesisHash"));
            rollupParams.submitBlobsWindow = vm.envOr("ROLLUP_SUBMIT_BLOBS_WINDOW", json.readUint(".rollup.submitBlobsWindow"));
            rollupParams.preconfirmWindow = vm.envOr("ROLLUP_PRECONFIRM_WINDOW", json.readUint(".rollup.preconfirmWindow"));
            rollupParams.challengeWindow = vm.envOr("ROLLUP_CHALLENGE_WINDOW", json.readUint(".rollup.challengeWindow"));
            rollupParams.finalizationDelay = vm.envOr("ROLLUP_FINALIZATION_DELAY", json.readUint(".rollup.finalizationDelay"));
            rollupParams.challengeDepositAmount = vm.envOr("ROLLUP_CHALLENGE_DEPOSIT_AMOUNT", json.readUint(".rollup.challengeDepositAmount"));
            rollupParams.incentiveFee = vm.envOr("ROLLUP_INCENTIVE_FEE", json.readUint(".rollup.incentiveFee"));
            rollupParams.acceptDepositDeadline = vm.envOr("ROLLUP_ACCEPT_DEPOSIT_DEADLINE", json.readUint(".rollup.acceptDepositDeadline"));

            (d.rollup, d.rollupImpl) = _deployRollup(rollupParams);
        }

        // 4. Close circular dependency: bridge → rollup
        L1FluentBridge(payable(d.bridge)).setRollup(d.rollup);

        // 5. ERC20 factory + ERC20 gateway
        {
            ERC20FactoryResult memory factoryResult = _deployERC20TokenFactory(initialOwner);
            d.peggedImpl = factoryResult.peggedImpl;
            d.factoryImpl = factoryResult.factoryImpl;
            d.factory = factoryResult.factory;
            d.factoryBeacon = factoryResult.factoryBeacon;

            ERC20GatewayResult memory gatewayResult = _deployERC20Gateway(initialOwner, d.bridge, d.factory);
            d.erc20GatewayImpl = gatewayResult.gatewayImpl;
            d.erc20Gateway = gatewayResult.gateway;

            ERC20TokenFactory(d.factory).setPaymentGateway(d.erc20Gateway);
        }

        // 6. NativeGateway
        d.nativeGateway = Upgrades.deployUUPSProxy(
            "NativeGateway.sol:NativeGateway",
            abi.encodeCall(NativeGateway.initialize, (initialOwner, d.bridge))
        );
        d.nativeGatewayImpl = Upgrades.getImplementationAddress(d.nativeGateway);

        // 7. Mock token (testnet only)
        d.mockToken = _deployMockFromEnv(initialOwner);

        vm.stopBroadcast();

        // Phase 3: Artifacts
        if (bytes(outputPath).length != 0) {
            _writeOutput(outputPath, d);
        }
    }

    function _deployMockFromEnv(address initialOwner) internal returns (address) {
        string memory mockName = vm.envOr("MOCK_ERC20_NAME", string("Mock Deposit Token"));
        string memory mockSymbol = vm.envOr("MOCK_ERC20_SYMBOL", string("MDT"));
        uint256 mockSupply = vm.envOr("MOCK_ERC20_SUPPLY", uint256(1_000_000 ether));
        address mockRecipient = vm.envOr("MOCK_ERC20_RECIPIENT", initialOwner);
        return _deployMockERC20(mockName, mockSymbol, mockSupply, mockRecipient);
    }

    function _writeOutput(string memory outputPath, Deployment memory d) internal {
        string memory out = vm.serializeAddress("deployment", "nitro_verifier", d.nitroVerifier);
        out = vm.serializeAddress("deployment", "bridge", d.bridge);
        out = vm.serializeAddress("deployment", "bridge_impl", d.bridgeImpl);
        out = vm.serializeAddress("deployment", "rollup", d.rollup);
        out = vm.serializeAddress("deployment", "rollup_impl", d.rollupImpl);
        out = vm.serializeAddress("deployment", "pegged_impl", d.peggedImpl);
        out = vm.serializeAddress("deployment", "factory_impl", d.factoryImpl);
        out = vm.serializeAddress("deployment", "factory", d.factory);
        out = vm.serializeAddress("deployment", "factory_beacon", d.factoryBeacon);
        out = vm.serializeAddress("deployment", "erc20_gateway_impl", d.erc20GatewayImpl);
        out = vm.serializeAddress("deployment", "erc20_gateway", d.erc20Gateway);
        out = vm.serializeAddress("deployment", "native_gateway_impl", d.nativeGatewayImpl);
        out = vm.serializeAddress("deployment", "native_gateway", d.nativeGateway);
        out = vm.serializeAddress("deployment", "mock_token", d.mockToken);
        vm.writeJson(out, outputPath);
    }
}
