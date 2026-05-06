// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

import {DeployNativeGateway} from "./DeployNativeGateway.s.sol";
import {DeployNitroVerifier} from "./DeployNitroVerifier.s.sol";
import {DeployRollup} from "./DeployRollup.s.sol";
import {InitConfiguration} from "../../contracts/interfaces/rollup/IRollupTypes.sol";

/// @notice Sepolia-focused wrapper for simulating a standalone L1 NativeGateway deployment.
/// @dev Also deploys NitroVerifier and Rollup using testnet config defaults.
contract DeploySepolia is DeployNativeGateway, DeployNitroVerifier, DeployRollup {
    using stdJson for string;

    function run() external override(DeployNativeGateway, DeployNitroVerifier, DeployRollup) {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        address bridge = vm.envOr("BRIDGE_ADDRESS", address(0x9CAcf613fC29015893728563f423fD26dCdB8Ddc));
        string memory json = _readConfig(vm.envOr("NETWORK", string("testnet/l1")));
        address adminRole = vm.envOr("ADMIN_ROLE", initialOwner);
        address sp1Verifier = vm.envOr("SP1_VERIFIER", json.readAddress(".rollup.sp1Verifier"));
        uint256 submitBlobsWindow = vm.envOr("ROLLUP_SUBMIT_BLOBS_WINDOW", json.readUint(".rollup.submitBlobsWindow"));
        uint256 preconfirmWindow = vm.keyExistsJson(json, ".rollup.preconfirmWindow")
            ? vm.envOr("ROLLUP_PRECONFIRM_WINDOW", json.readUint(".rollup.preconfirmWindow"))
            : vm.envOr("ROLLUP_PRECONFIRM_WINDOW", submitBlobsWindow);
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying Sepolia contracts");
        console2.log("  initialOwner:", initialOwner);
        console2.log("  admin:", adminRole);
        console2.log("  bridge:", bridge);
        console2.log("  sp1Verifier:", sp1Verifier);
        console2.log("  preconfirmWindow:", preconfirmWindow);

        vm.startBroadcast();
        NativeGatewayResult memory nativeGateway = _deployNativeGateway(initialOwner, bridge);
        address nitroVerifier = _deployNitroVerifier(sp1Verifier, adminRole);
        InitConfiguration memory rollupConfig;
        rollupConfig.admin = adminRole;
        rollupConfig.emergency = vm.envOr("ROLLUP_EMERGENCY", json.readAddress(".rollup.emergency"));
        rollupConfig.sequencer = vm.envOr("ROLLUP_SEQUENCER", json.readAddress(".rollup.sequencer"));
        rollupConfig.challenger = vm.envOr("ROLLUP_CHALLENGER", json.readAddress(".rollup.challenger"));
        rollupConfig.prover = vm.envOr("ROLLUP_PROVER", json.readAddress(".rollup.prover"));
        rollupConfig.preconfirmationRole = vm.envOr("ROLLUP_PRECONFIRMATION_ROLE", json.readAddress(".rollup.preconfirmation"));
        rollupConfig.sp1Verifier = sp1Verifier;
        rollupConfig.nitroVerifier = nitroVerifier;
        rollupConfig.bridge = bridge;
        rollupConfig.programVKey = vm.envOr("ROLLUP_PROGRAM_VKEY", json.readBytes32(".rollup.programVKey"));
        rollupConfig.genesisBlockHash = vm.envOr("ROLLUP_GENESIS_BLOCK_HASH", json.readBytes32(".rollup.genesisHash"));
        rollupConfig.challengeDepositAmount =
            vm.envOr("ROLLUP_CHALLENGE_DEPOSIT_AMOUNT", json.readUint(".rollup.challengeDepositAmount"));
        rollupConfig.challengeWindow = vm.envOr("ROLLUP_CHALLENGE_WINDOW", json.readUint(".rollup.challengeWindow"));
        rollupConfig.finalizationDelay = vm.envOr("ROLLUP_FINALIZATION_DELAY", json.readUint(".rollup.finalizationDelay"));
        rollupConfig.incentiveFee = vm.envOr("ROLLUP_INCENTIVE_FEE", json.readUint(".rollup.incentiveFee"));
        rollupConfig.submitBlobsWindow = submitBlobsWindow;
        rollupConfig.preconfirmWindow = preconfirmWindow;
        RollupResult memory rollup = _deployRollup(rollupConfig);
        vm.stopBroadcast();

        console2.log("NativeGateway deployed:", nativeGateway.gateway);
        console2.log("  impl:", nativeGateway.gatewayImpl);
        console2.log("NitroVerifier deployed:", nitroVerifier);
        console2.log("Rollup deployed:", rollup.proxy);
        console2.log("  impl:", rollup.impl);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "native_gateway", nativeGateway.gateway);
            out = vm.serializeAddress("deployment", "native_gateway_impl", nativeGateway.gatewayImpl);
            out = vm.serializeAddress("deployment", "nitro_verifier", nitroVerifier);
            out = vm.serializeAddress("deployment", "rollup", rollup.proxy);
            out = vm.serializeAddress("deployment", "rollup_impl", rollup.impl);
            vm.writeJson(out, outputPath);
        }
    }
}
