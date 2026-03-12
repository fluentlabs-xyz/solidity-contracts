// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseScript} from "../Base.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";

/// @notice Upgrades the ERC20 pegged token beacon via the factory.
/// @dev Expects msg.sender to be the owner of the factory proxy.
contract UpgradeERC20Beacon is BaseScript {
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
