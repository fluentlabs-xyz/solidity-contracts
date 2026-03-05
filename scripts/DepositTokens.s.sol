// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseScript} from "./Base.sol";
import {PaymentsGateway} from "../contracts/gateways/PaymentsGateway.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deposits ERC20 tokens into a PaymentsGateway, initiating a bridge transfer.
/// @dev Environment:
/// - GATEWAY_ADDRESS (address, required): PaymentsGateway contract address
/// - TOKEN_ADDRESS   (address, required): ERC20 token to deposit (origin token)
/// - RECIPIENT       (address, required): destination-chain recipient
/// - AMOUNT          (uint256, required): token amount (in token units)
contract DepositTokens is BaseScript {
    function run() external {
        address gatewayAddress = vm.envAddress("GATEWAY_ADDRESS");
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        address recipient = vm.envAddress("RECIPIENT");
        uint256 amount = vm.envOr("AMOUNT", uint256(0));
        require(amount > 0, "AMOUNT must be > 0");

        PaymentsGateway gateway = PaymentsGateway(payable(gatewayAddress));
        IERC20 token = IERC20(tokenAddress);

        vm.startBroadcast();
        token.approve(gatewayAddress, amount);
        gateway.sendTokens(tokenAddress, recipient, amount);
        vm.stopBroadcast();
    }
}

