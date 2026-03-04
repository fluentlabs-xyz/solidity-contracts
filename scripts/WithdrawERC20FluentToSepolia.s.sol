// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseScript} from "./Base.sol";
import {PaymentsGateway} from "../contracts/gateways/PaymentsGateway.sol";

/// @notice Burns pegged ERC20 on L2 via PaymentsGateway and sends a withdrawal message to L1.
/// @dev Environment:
/// - GATEWAY_ADDRESS      (address, required): L2 PaymentsGateway address
/// - ORIGIN_TOKEN_ADDRESS (address, required): L1 origin token address
/// - RECIPIENT_ADDRESS    (address, required): L1 recipient of the unlocked tokens
/// - AMOUNT               (uint256, required): amount to withdraw (in pegged token units)
contract WithdrawERC20FluentToSepolia is BaseScript {
    function run() external {
        address gatewayAddress = vm.envAddress("GATEWAY_ADDRESS");
        address originToken = vm.envAddress("ORIGIN_TOKEN_ADDRESS");
        address recipient = vm.envAddress("RECIPIENT_ADDRESS");
        uint256 amount = vm.envOr("AMOUNT", uint256(0));
        require(amount > 0, "AMOUNT must be > 0");

        PaymentsGateway gateway = PaymentsGateway(payable(gatewayAddress));
        address peggedToken = gateway.computePeggedTokenAddress(originToken);
        require(peggedToken != address(0), "pegged token not configured");

        vm.startBroadcast();
        gateway.sendTokens(peggedToken, recipient, amount);
        vm.stopBroadcast();
    }
}

