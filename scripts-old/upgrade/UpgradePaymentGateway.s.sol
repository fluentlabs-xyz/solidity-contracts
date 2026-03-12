// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseScript} from "../Base.sol";
import {PaymentGateway} from "../../contracts/gateways/PaymentGateway.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @notice Upgrades a PaymentGateway (UUPS) proxy to the current implementation.
/// @dev Env: GATEWAY_PROXY (address). Uses UnsafeUpgrades (no artifact lookup, no upgrade validations).
contract UpgradePaymentGateway is BaseScript {
    function run() external {
        address proxy = vm.envAddress("GATEWAY_PROXY");

        vm.startBroadcast();
        PaymentGateway newImpl = new PaymentGateway();
        UnsafeUpgrades.upgradeProxy(proxy, address(newImpl), "");
        vm.stopBroadcast();
    }
}
