// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {InitConfiguration} from "../../contracts/interfaces/IRollupTypes.sol";
import {SP1Verifier} from "../../contracts/verifier/SP1VerifierGroth16.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Deployment script for the Rollup contract behind an ERC1967 proxy (UUPS upgradeable).
///
/// All window parameters are measured from `acceptedAtBlock` (the block where
/// `acceptNextBatch` was called). Ethereum mainnet: 1 block ≈ 12 seconds.
///
///   submitBlobsWindow  =  7200 blocks (~24 hours) — sequencer must submit all blob hashes
///   preconfirmWindow   =  7200 blocks (~24 hours) — preconfirmer must confirm the batch
///   challengeWindow    = 10800 blocks (~36 hours) — challenge must be resolved by this block
///   finalizationDelay  = 14400 blocks (~48 hours) — earliest block a batch can be finalized

contract DeployRollup is Script {
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
        // All windows are measured from acceptedAtBlock — the block where
        // acceptNextBatch was called. Each window defines a deadline independently.
        //
        // submitBlobsWindow: sequencer must submit all blob hashes before this deadline.
        // preconfirmWindow:  preconfirmer must call preconfirmBatch before this deadline.
        //                    Must be >= submitBlobsWindow.
        // challengeWindow:   open challenge must be resolved before acceptedAtBlock + challengeWindow.
        //                    Measured from acceptedAtBlock, not from challenge creation time.
        // finalizationDelay: batch cannot be finalized before acceptedAtBlock + finalizationDelay.
        //                    Must exceed challengeWindow so challengers always have time to act.
        params.submitBlobsWindow = vm.envOr("ROLLUP_SUBMIT_BLOBS_WINDOW", uint256(BLOCKS_PER_DAY)); // 24 h
        params.preconfirmWindow = vm.envOr("ROLLUP_PRECONFIRM_WINDOW", uint256(BLOCKS_PER_DAY)); // 24 h
        params.challengeWindow = vm.envOr("ROLLUP_CHALLENGE_WINDOW", uint256(BLOCKS_PER_DAY + BLOCKS_PER_HOUR * 12)); // 36 h
        params.finalizationDelay = vm.envOr("ROLLUP_FINALIZATION_DELAY", uint256(BLOCKS_PER_DAY * 2)); // 48 h

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
