// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {InitConfiguration} from "../../contracts/interfaces/IRollupTypes.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys Rollup behind a UUPS proxy with full OZ upgrade validation.
/// @dev Inherit and call _deployRollup() inside your broadcast. Use _readRollupParams() to read config.
contract DeployRollup is DeployBase {
    using stdJson for string;

    struct RollupResult {
        address proxy;
        address impl;
    }

    function _readRollupParams(string memory json, address adminRole, address nitroVerifier) internal returns (InitConfiguration memory p) {
        p.admin = adminRole;
        p.emergency = vm.envOr("ROLLUP_EMERGENCY", json.readAddress(".rollup.emergency"));
        p.sequencer = vm.envOr("ROLLUP_SEQUENCER", json.readAddress(".rollup.sequencer"));
        p.challenger = vm.envOr("ROLLUP_CHALLENGER", json.readAddress(".rollup.challenger"));
        p.prover = vm.envOr("ROLLUP_PROVER", json.readAddress(".rollup.prover"));
        p.preconfirmationRole = vm.envOr("ROLLUP_PRECONFIRMATION_ROLE", json.readAddress(".rollup.preconfirmation"));
        p.nitroVerifier = nitroVerifier;
        p.sp1Verifier = vm.envOr("SP1_VERIFIER", json.readAddress(".rollup.sp1Verifier"));
        p.programVKey = vm.envOr("ROLLUP_PROGRAM_VKEY", json.readBytes32(".rollup.programVKey"));
        p.genesisHash = vm.envOr("ROLLUP_GENESIS_HASH", json.readBytes32(".rollup.genesisHash"));
        p.submitBlobsWindow = vm.envOr("ROLLUP_SUBMIT_BLOBS_WINDOW", json.readUint(".rollup.submitBlobsWindow"));
        p.preconfirmWindow = vm.envOr("ROLLUP_PRECONFIRM_WINDOW", json.readUint(".rollup.preconfirmWindow"));
        p.challengeWindow = vm.envOr("ROLLUP_CHALLENGE_WINDOW", json.readUint(".rollup.challengeWindow"));
        p.finalizationDelay = vm.envOr("ROLLUP_FINALIZATION_DELAY", json.readUint(".rollup.finalizationDelay"));
        p.challengeDepositAmount = vm.envOr("ROLLUP_CHALLENGE_DEPOSIT_AMOUNT", json.readUint(".rollup.challengeDepositAmount"));
        p.incentiveFee = vm.envOr("ROLLUP_INCENTIVE_FEE", json.readUint(".rollup.incentiveFee"));
        p.acceptDepositDeadline = vm.envOr("ROLLUP_ACCEPT_DEPOSIT_DEADLINE", json.readUint(".rollup.acceptDepositDeadline"));
        p.maxForceRevertBatchSize = vm.envOr("ROLLUP_MAX_FORCE_REVERT_BATCH_SIZE", json.readUint(".rollup.maxForceRevertBatchSize"));
    }

    function _deployRollup(InitConfiguration memory params) internal returns (RollupResult memory r) {
        bytes memory initData = abi.encodeCall(Rollup.initialize, (abi.encode(params)));
        r.proxy = Upgrades.deployUUPSProxy("Rollup.sol:Rollup", initData);
        r.impl = Upgrades.getImplementationAddress(r.proxy);
    }

    /// @dev Standalone: NETWORK, NITRO_VERIFIER, BRIDGE_ADDRESS required.
    function run() external virtual {
        string memory json = _readConfig(vm.envOr("NETWORK", string("testnet/l1")));
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));
        address adminRole = vm.envOr("ROLLUP_ADMIN", json.readAddress(".roles.admin"));
        address nitroVerifier = vm.envAddress("NITRO_VERIFIER");
        address bridge = vm.envAddress("BRIDGE_ADDRESS");

        InitConfiguration memory p = _readRollupParams(json, adminRole, nitroVerifier);
        p.bridge = bridge;

        console2.log("Deploying Rollup");
        console2.log("  admin:", p.admin);
        console2.log("  bridge:", p.bridge);
        console2.log("  nitroVerifier:", p.nitroVerifier);

        vm.startBroadcast();
        RollupResult memory r = _deployRollup(p);
        vm.stopBroadcast();

        console2.log("Rollup deployed:", r.proxy);
        console2.log("  impl:", r.impl);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "rollup", r.proxy);
            out = vm.serializeAddress("deployment", "rollup_impl", r.impl);
            vm.writeJson(out, outputPath);
        }
    }
}
