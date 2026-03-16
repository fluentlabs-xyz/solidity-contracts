// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseScript} from "../Base.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {InitConfiguration} from "../../contracts/interfaces/IRollupTypes.sol";
import {SP1Verifier} from "../../contracts/verifier/SP1VerifierGroth16.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Deployment script for the Rollup contract behind an ERC1967 proxy (UUPS upgradeable).
///
/// Window parameters (Ethereum mainnet, ~12s per block):
///   submitBlobsWindow  =  600 blocks (~2 hours)  — sequencer must submit all blob hashes
///   preconfirmWindow   =  900 blocks (~3 hours)  — preconfirmer must confirm the batch
///   finalizationDelay  = 7200 blocks (~24 hours) — challenge window open to verifiers
///   challengeWindow    = 1200 blocks (~4 hours)  — prover must resolve an open challenge
///
/// Invariants enforced by the contract:
///   submitBlobsWindow (600) < preconfirmWindow (900)
///   challengeWindow  (1200) < finalizationDelay (7200)
contract DeployRollup is BaseScript {
    event RollupDeployed(address indexed implementation, address indexed proxy);

    /// @dev Ethereum mainnet: 1 block ≈ 12 seconds
    uint256 internal constant BLOCKS_PER_HOUR = 300;
    uint256 internal constant BLOCKS_PER_DAY = 7200;

    function run() external returns (address rollupProxy) {
        address admin = vm.envAddress("ROLLUP_INITIAL_OWNER");

        InitConfiguration memory params;

        // ─── Roles ───
        params.admin = admin;
        params.emergency = vm.envOr("ROLLUP_EMERGENCY", address(0));
        params.sequencer = vm.envAddress("ROLLUP_SEQUENCER");
        params.challenger = vm.envOr("ROLLUP_CHALLENGER", address(0));
        params.prover = vm.envOr("ROLLUP_PROVER", address(0));
        params.preconfirmationRole = vm.envOr("ROLLUP_PRECONFIRMATION_ROLE", address(0));
        params.nitroVerifier = vm.envOr("ROLLUP_NITRO_VERIFIER", address(0));

        // ─── Infrastructure ───
        params.bridge = vm.envAddress("ROLLUP_BRIDGE");
        params.programVKey = bytes32(vm.envOr("ROLLUP_PROGRAM_VKEY", uint256(0)));
        params.genesisHash = bytes32(vm.envOr("ROLLUP_GENESIS_HASH", uint256(0)));

        // ─── Timing parameters ───
        // submitBlobsWindow: how long the sequencer has to submit blob hashes after acceptNextBatch.
        // preconfirmWindow:  how long the preconfirmer has to confirm after blobs are submitted.
        //                    Must exceed submitBlobsWindow — both are measured from acceptedAtBlock.
        // finalizationDelay: blocks after acceptance before a batch can be finalized.
        //                    Must exceed challengeWindow so challengers always get the full window.
        // challengeWindow:   blocks a prover has to resolve an open challenge before corruption.
        params.submitBlobsWindow = vm.envOr("ROLLUP_SUBMIT_BLOBS_WINDOW", uint256(BLOCKS_PER_HOUR * 2));
        params.preconfirmWindow = vm.envOr("ROLLUP_PRECONFIRM_WINDOW", uint256(BLOCKS_PER_HOUR * 3));
        params.finalizationDelay = vm.envOr("ROLLUP_FINALIZATION_DELAY", uint256(BLOCKS_PER_DAY));
        params.challengeWindow = vm.envOr("ROLLUP_CHALLENGE_WINDOW", uint256(BLOCKS_PER_HOUR * 4));

        // ─── Economic parameters ───
        params.challengeDepositAmount = vm.envOr("ROLLUP_CHALLENGE_DEPOSIT_AMOUNT", uint256(0.01 ether));
        params.incentiveFee = vm.envOr("ROLLUP_INCENTIVE_FEE", uint256(0.001 ether));
        params.acceptDepositDeadline = vm.envOr("ROLLUP_ACCEPT_DEPOSIT_DEADLINE", uint256(10_000));

        string memory outputPath = vm.envOr("ROLLUP_OUTPUT_PATH", string(""));

        vm.startBroadcast();

        SP1Verifier sp1Verifier = new SP1Verifier();
        params.sp1Verifier = address(sp1Verifier);

        Rollup rollupImpl = new Rollup();
        bytes memory initData = abi.encodeCall(Rollup.initialize, (abi.encode(params)));
        ERC1967Proxy rollupProxyContract = new ERC1967Proxy(address(rollupImpl), initData);

        vm.stopBroadcast();

        rollupProxy = address(rollupProxyContract);
        emit RollupDeployed(address(rollupImpl), rollupProxy);

        if (bytes(outputPath).length != 0) {
            string memory json = vm.serializeAddress("rollup_deployment", "rollup_impl", address(rollupImpl));
            json = vm.serializeAddress("rollup_deployment", "rollup_sp1_verifier", address(sp1Verifier));
            json = vm.serializeAddress("rollup_deployment", "rollup", rollupProxy);
            vm.writeJson(json, outputPath);
        }
    }
}
