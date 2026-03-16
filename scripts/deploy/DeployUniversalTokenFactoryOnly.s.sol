// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Deploys only the UniversalTokenFactory (no token). Use this to get real on-chain txs when token deploy fails.
/// @dev Environment: INITIAL_OWNER (address). Optional: OUTPUT_PATH (string).
contract DeployUniversalTokenFactoryOnly is Script {
    struct Deployment {
        address factoryImpl;
        address factory;
    }

    function run() external returns (Deployment memory deployed) {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string("deployments/universal-token-factory-only.json"));

        vm.startBroadcast();

        UniversalTokenFactory factoryImpl = new UniversalTokenFactory();
        ERC1967Proxy factoryProxyContract = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(UniversalTokenFactory.initialize, (initialOwner))
        );

        vm.stopBroadcast();

        deployed = Deployment({factoryImpl: address(factoryImpl), factory: address(factoryProxyContract)});

        if (bytes(outputPath).length != 0) {
            string memory json = vm.serializeAddress("deployment", "factory_impl", deployed.factoryImpl);
            json = vm.serializeAddress("deployment", "factory", deployed.factory);
            vm.writeJson(json, outputPath);
        }
    }
}
