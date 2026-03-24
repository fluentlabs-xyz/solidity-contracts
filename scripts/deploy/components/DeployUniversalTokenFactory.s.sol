// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {DeployLib} from "./DeployLib.s.sol";

/**
 * @notice Deployment script for UniversalTokenFactory (L2): impl + proxy.
 * @dev Environment: INITIAL_OWNER (address), OUTPUT_PATH (string, optional).
 */
contract DeployUniversalTokenFactory is DeployLib {
    function run() external returns (address factoryProxy) {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        vm.startBroadcast();
        address factoryImpl;
        (factoryProxy, factoryImpl) = _deployUniversalTokenFactory(initialOwner);
        vm.stopBroadcast();

        if (bytes(outputPath).length != 0) {
            string memory json = vm.serializeAddress("deployment", "factory_impl", factoryImpl);
            json = vm.serializeAddress("deployment", "factory", factoryProxy);
            vm.writeJson(json, outputPath);
        }
    }
}
