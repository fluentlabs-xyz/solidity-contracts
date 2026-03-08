// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseScript} from "../Base.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {RollupStorageLayout} from "../../contracts/rollup/RollupStorageLayout.sol";
import {SP1Verifier} from "../../contracts/verifier/SP1VerifierGroth16.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Deployment script for the Rollup contract behind an ERC1967 proxy (UUPS upgradeable).
contract DeployRollup is BaseScript {
    event RollupDeployed(address indexed implementation, address indexed proxy);

    function run() external returns (address rollupProxy) {
        address admin = vm.envAddress("ROLLUP_INITIAL_OWNER");
        address pauser = vm.envOr("ROLLUP_PAUSER", address(0));
        RollupStorageLayout.InitConfiguration memory params;
        params.admin = admin;
        params.pauser = pauser;
        params.sequencer = vm.envAddress("ROLLUP_SEQUENCER");
        params.challengeDepositAmount = vm.envOr("ROLLUP_CHALLENGE_DEPOSIT_AMOUNT", uint256(0.01 ether));
        params.challengeBlockCount = vm.envOr("ROLLUP_CHALLENGE_BLOCK_COUNT", uint256(1_000));
        params.approveBlockCount = vm.envOr("ROLLUP_APPROVE_BLOCK_COUNT", uint256(5_000));
        params.programVKey = bytes32(vm.envOr("ROLLUP_PROGRAM_VKEY", uint256(0)));
        params.genesisHash = bytes32(vm.envOr("ROLLUP_GENESIS_HASH", uint256(0)));
        params.bridge = vm.envAddress("ROLLUP_BRIDGE");
        params.batchSize = vm.envOr("ROLLUP_BATCH_SIZE", uint256(32));
        params.acceptDepositDeadline = vm.envOr("ROLLUP_ACCEPT_DEPOSIT_DEADLINE", uint256(10_000));
        params.incentiveFee = vm.envOr("ROLLUP_INCENTIVE_FEE", uint256(0.001 ether));
        params.challenger = vm.envOr("ROLLUP_CHALLENGER", address(0));
        params.prover = vm.envOr("ROLLUP_PROVER", address(0));

        string memory outputPath = vm.envOr("ROLLUP_OUTPUT_PATH", string(""));

        vm.startBroadcast();

        SP1Verifier verifierImpl = new SP1Verifier();
        Rollup rollupImpl = new Rollup();

        params.verifier = address(verifierImpl);
        bytes memory initData = abi.encodeCall(Rollup.initialize, (abi.encode(params)));

        ERC1967Proxy rollupProxyContract = new ERC1967Proxy(address(rollupImpl), initData);

        vm.stopBroadcast();

        rollupProxy = address(rollupProxyContract);
        emit RollupDeployed(address(rollupImpl), rollupProxy);

        if (bytes(outputPath).length != 0) {
            string memory json = vm.serializeAddress("rollup_deployment", "rollup_impl", address(rollupImpl));
            json = vm.serializeAddress("rollup_deployment", "rollup_verifier_impl", address(verifierImpl));
            json = vm.serializeAddress("rollup_deployment", "rollup", rollupProxy);
            vm.writeJson(json, outputPath);
        }
    }
}
