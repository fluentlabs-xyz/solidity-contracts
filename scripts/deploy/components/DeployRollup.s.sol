// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";

import {DeployLib} from "./DeployLib.s.sol";
import {InitConfiguration} from "../../../contracts/interfaces/IRollupTypes.sol";

/// @notice Deployment script for the Rollup contract behind a UUPS proxy.
///
/// All window parameters are measured from `acceptedAtBlock` (the block where
/// `acceptNextBatch` was called). Ethereum mainnet: 1 block ≈ 12 seconds.
///
///   submitBlobsWindow  =  7200 blocks (~24 hours) — sequencer must submit all blob hashes
///   preconfirmWindow   =  7200 blocks (~24 hours) — preconfirmer must confirm the batch
///   challengeWindow    = 10800 blocks (~36 hours) — challenge must be resolved by this block
///   finalizationDelay  = 14400 blocks (~48 hours) — earliest block a batch can be finalized
///
/// @dev Reads chain config from scripts/input/<NETWORK>.json. Env vars override JSON values.
///      Requires ALLOW_UNSAFE_UPGRADES=true.
contract DeployRollup is DeployLib {
    using stdJson for string;
    /// @dev Ethereum mainnet: 1 block ≈ 12 seconds
    uint256 internal constant BLOCKS_PER_HOUR = 300;
    uint256 internal constant BLOCKS_PER_DAY = 7200;

    function run() external returns (address rollupProxy) {
        // Phase 1: Config
        string memory network = vm.envOr("NETWORK", string("testnet/l1"));
        string memory json = _readConfig(network);
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        InitConfiguration memory params;

        // ─── Roles (JSON with env var overrides) ───
        params.admin = vm.envOr("ROLLUP_INITIAL_OWNER", json.readAddress(".roles.admin"));
        params.emergency = vm.envOr("ROLLUP_EMERGENCY", json.readAddress(".rollup.emergency"));
        params.sequencer = vm.envOr("ROLLUP_SEQUENCER", json.readAddress(".rollup.sequencer"));
        params.challenger = vm.envOr("ROLLUP_CHALLENGER", json.readAddress(".rollup.challenger"));
        params.prover = vm.envOr("ROLLUP_PROVER", json.readAddress(".rollup.prover"));
        params.preconfirmationRole = vm.envOr("ROLLUP_PRECONFIRMATION_ROLE", json.readAddress(".rollup.preconfirmation"));
        params.nitroVerifier = vm.envAddress("ROLLUP_NITRO_VERIFIER");
        params.sp1Verifier = vm.envOr("SP1_VERIFIER", json.readAddress(".rollup.sp1Verifier"));

        // ─── Infrastructure ───
        params.bridge = vm.envAddress("ROLLUP_BRIDGE");
        params.programVKey = vm.envOr("ROLLUP_PROGRAM_VKEY", json.readBytes32(".rollup.programVKey"));
        params.genesisHash = vm.envOr("ROLLUP_GENESIS_HASH", json.readBytes32(".rollup.genesisHash"));

        // ─── Timing parameters ───
        params.submitBlobsWindow = vm.envOr("ROLLUP_SUBMIT_BLOBS_WINDOW", json.readUint(".rollup.submitBlobsWindow"));
        params.preconfirmWindow = vm.envOr("ROLLUP_PRECONFIRM_WINDOW", json.readUint(".rollup.preconfirmWindow"));
        params.challengeWindow = vm.envOr("ROLLUP_CHALLENGE_WINDOW", json.readUint(".rollup.challengeWindow"));
        params.finalizationDelay = vm.envOr("ROLLUP_FINALIZATION_DELAY", json.readUint(".rollup.finalizationDelay"));

        // ─── Economic parameters ───
        params.challengeDepositAmount = vm.envOr("ROLLUP_CHALLENGE_DEPOSIT_AMOUNT", json.readUint(".rollup.challengeDepositAmount"));
        params.incentiveFee = vm.envOr("ROLLUP_INCENTIVE_FEE", json.readUint(".rollup.incentiveFee"));
        params.acceptDepositDeadline = vm.envOr("ROLLUP_ACCEPT_DEPOSIT_DEADLINE", json.readUint(".rollup.acceptDepositDeadline"));
        params.maxForceRevertBatchSize = vm.envOr("ROLLUP_MAX_FORCE_REVERT_BATCH_SIZE", json.readUint(".rollup.maxForceRevertBatchSize"));

        // Phase 2: Deploy
        vm.startBroadcast();
        address rollupImpl;
        (rollupProxy, rollupImpl) = _deployRollup(params);
        vm.stopBroadcast();

        // Phase 3: Artifacts
        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "rollup_impl", rollupImpl);
            out = vm.serializeAddress("deployment", "rollup_sp1_verifier", params.sp1Verifier);
            out = vm.serializeAddress("deployment", "rollup", rollupProxy);
            vm.writeJson(out, outputPath);
        }
    }
}
