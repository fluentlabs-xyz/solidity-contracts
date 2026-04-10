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
        p.challengeWindow = vm.envOr("ROLLUP_CHALLENGE_WINDOW", json.readUint(".rollup.challengeWindow"));
        p.finalizationDelay = vm.envOr("ROLLUP_FINALIZATION_DELAY", json.readUint(".rollup.finalizationDelay"));
        p.challengeDepositAmount = vm.envOr("ROLLUP_CHALLENGE_DEPOSIT_AMOUNT", json.readUint(".rollup.challengeDepositAmount"));
        p.incentiveFee = vm.envOr("ROLLUP_INCENTIVE_FEE", json.readUint(".rollup.incentiveFee"));
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

        /// @dev We are using existing SP1 Verifier - https://docs.succinct.xyz/docs/sp1/verification/contract-addresses
        /// https://sepolia.etherscan.io/address/0x397A5f7f3dBd538f23DE225B51f532c34448dA9B
        params.sp1Verifier = vm.envOr("SP1_VERIFIER", address(0x397A5f7f3dBd538f23DE225B51f532c34448dA9B));

        // ─── Infrastructure ───
        params.bridge = vm.envAddress("ROLLUP_BRIDGE");
        params.programVKey = bytes32(vm.envOr("ROLLUP_PROGRAM_VKEY", uint256(0)));

        // ─── Timing parameters ───
        // All windows are measured from acceptedAtBlock — the block where
        // commitBatch was called. Each window defines a deadline independently.
        //
        // submitBlobsWindow: sequencer must submit all blob hashes before this deadline.
        // challengeWindow:   open challenge must be resolved before acceptedAtBlock + challengeWindow.
        //                    Measured from acceptedAtBlock, not from challenge creation time.
        // finalizationDelay: batch cannot be finalized before acceptedAtBlock + finalizationDelay.
        //                    Must exceed challengeWindow so challengers always have time to act.
        params.submitBlobsWindow = vm.envOr("ROLLUP_SUBMIT_BLOBS_WINDOW", uint256(BLOCKS_PER_DAY)); // 24 h
        params.preconfirmWindow = vm.envOr("ROLLUP_PRECONFIRM_WINDOW", uint256(BLOCKS_PER_DAY + BLOCKS_PER_HOUR * 6)); // 30 h
        params.challengeWindow = vm.envOr("ROLLUP_CHALLENGE_WINDOW", uint256(BLOCKS_PER_DAY + BLOCKS_PER_HOUR * 12)); // 36 h
        params.finalizationDelay = vm.envOr("ROLLUP_FINALIZATION_DELAY", uint256(BLOCKS_PER_DAY * 2)); // 48 h

        // ─── Economic parameters ───
        params.challengeDepositAmount = vm.envOr("ROLLUP_CHALLENGE_DEPOSIT_AMOUNT", uint256(0.01 ether));
        params.incentiveFee = vm.envOr("ROLLUP_INCENTIVE_FEE", uint256(0.001 ether));
        params.maxForceRevertBatchSize = vm.envOr("ROLLUP_MAX_FORCE_REVERT_BATCH_SIZE", uint256(10));

        string memory outputPath = vm.envOr("ROLLUP_OUTPUT_PATH", string(""));

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
