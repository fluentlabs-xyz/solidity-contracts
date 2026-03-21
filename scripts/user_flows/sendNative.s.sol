// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {NativeGateway} from "../../contracts/gateways/NativeGateway.sol";

/// @notice Sends native tokens via a NativeGateway, initiating a cross-chain transfer.
/// @dev Environment:
/// - GATEWAY_ADDRESS (address, required): NativeGateway contract address
/// - RECIPIENT       (address, required): destination-chain recipient
/// - AMOUNT_WEI      (uint256, optional): amount in wei (default: 0.01 ether)
contract SendNative is Script {
    function run() external {
        address gatewayAddress = vm.envAddress("GATEWAY_ADDRESS");
        address recipient = vm.envAddress("RECIPIENT");
        uint256 amountWei = vm.envOr("AMOUNT_WEI", uint256(0.01 ether));
        require(gatewayAddress != address(0), "GATEWAY_ADDRESS must not be zero");
        require(gatewayAddress.code.length > 0, "GATEWAY_ADDRESS must be a contract");
        require(amountWei > 0, "AMOUNT_WEI must be > 0");

        NativeGateway gateway = NativeGateway(payable(gatewayAddress));

        vm.startBroadcast();
        gateway.sendNativeTokens{value: amountWei}(recipient, amountWei);
        vm.stopBroadcast();
    }
}
