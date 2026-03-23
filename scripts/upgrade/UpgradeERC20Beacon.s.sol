// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";

/// @notice Upgrades the ERC20 pegged token beacon via the factory.
/// @dev Expects msg.sender to be the owner of the factory proxy.
contract UpgradeERC20Beacon is Script {
    event BeaconUpgraded(address indexed factory, address indexed newImplementation);

    function run() external {
        address factory = vm.envAddress("FACTORY_ADDRESS");
        address newImplementation = vm.envAddress("NEW_IMPLEMENTATION");

        vm.startBroadcast();
        ERC20TokenFactory(factory).upgradeTo(newImplementation);
        vm.stopBroadcast();

        emit BeaconUpgraded(factory, newImplementation);
    }
}
