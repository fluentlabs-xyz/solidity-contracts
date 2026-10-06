// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {AppDeposit} from "../../contracts/connect/AppDeposit.sol";

/// @notice Deploys the Fluent Connect {AppDeposit} contract on a Fluent Network and writes its manifest.
///
/// @dev The contract is stateless and ownerless, so a deploy is one CREATE and there is no setup step.
///      The address is then recorded in docs/Addresses.md and entered into the Network row of the
///      Fluent Connect catalogue.
///
/// Phases: (1) validate chain + EntryPoint, (2) broadcast deploy, (3) write manifest JSON.
///
/// Environment:
/// - ENV (optional, default testnet) selects the manifest directory and the expected chain id.
/// - OUTPUT_PATH (optional, default deployments/<ENV>/l2.app-deposit.json) receives the manifest.
///
/// Run (testnet, keystore account):
///   ENV=testnet forge script scripts/deploy/DeployAppDeposit.s.sol:DeployAppDeposit \
///     --rpc-url $L2_RPC --account $ACCOUNT --sender $SENDER --broadcast
contract DeployAppDeposit is Script {
    uint256 private constant FLUENT_TESTNET_CHAIN_ID = 20994;
    uint256 private constant FLUENT_MAINNET_CHAIN_ID = 25363;

    function run() external {
        // Phase 1: validate.
        string memory env = vm.envOr("ENV", string("testnet"));
        uint256 expectedChainId = _expectedChainId(env);
        require(block.chainid == expectedChainId, "chain id does not match ENV");
        require(address(0x0000000071727De22E5E9d8BAf0edAc6f37da032).code.length > 0, "EntryPoint v0.7 not deployed");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string.concat("deployments/", env, "/l2.app-deposit.json"));

        console2.log("Deploying AppDeposit");
        console2.log("  env:", env);
        console2.log("  outputPath:", outputPath);

        // Phase 2: deploy.
        vm.startBroadcast();
        AppDeposit appDeposit = new AppDeposit();
        vm.stopBroadcast();

        // Phase 3: write manifest.
        string memory out = vm.serializeUint("app-deposit", "chainId", block.chainid);
        out = vm.serializeAddress("app-deposit", "entry_point", address(appDeposit.ENTRY_POINT()));
        out = vm.serializeAddress("app-deposit", "app_deposit", address(appDeposit));
        vm.writeJson(out, outputPath);

        console2.log("AppDeposit:", address(appDeposit));
    }

    function _expectedChainId(string memory env) internal pure returns (uint256) {
        if (keccak256(bytes(env)) == keccak256("testnet")) return FLUENT_TESTNET_CHAIN_ID;
        if (keccak256(bytes(env)) == keccak256("mainnet")) return FLUENT_MAINNET_CHAIN_ID;
        revert("ENV must be testnet or mainnet");
    }
}
