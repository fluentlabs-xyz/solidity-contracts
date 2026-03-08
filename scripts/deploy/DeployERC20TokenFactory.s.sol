// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DeployLib} from "./DeployLib.s.sol";

/**
 * @notice Deployment script for the L1 ERC20 token factory stack (pegged impl, beacon, factory impl + proxy).
 * @dev Environment: INITIAL_OWNER (address), OUTPUT_PATH (string, optional).
 */
contract DeployERC20TokenFactory is DeployLib {
    function run() external returns (address factory) {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        vm.startBroadcast();
        ERC20FactoryResult memory r = _deployERC20TokenFactory(initialOwner);
        vm.stopBroadcast();

        factory = r.factory;
        if (bytes(outputPath).length != 0) {
            string memory json = vm.serializeAddress("deployment", "pegged_impl", r.peggedImpl);
            json = vm.serializeAddress("deployment", "factory_impl", r.factoryImpl);
            json = vm.serializeAddress("deployment", "factory_beacon", r.factoryBeacon);
            json = vm.serializeAddress("deployment", "factory", r.factory);
            vm.writeJson(json, outputPath);
        }
    }
}
