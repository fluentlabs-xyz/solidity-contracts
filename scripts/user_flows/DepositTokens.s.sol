// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Script} from "forge-std/Script.sol";
import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";

/// @notice Deposits ERC20 tokens into an ERC20Gateway, initiating a bridge transfer.
/// @dev Environment:
/// - GATEWAY_ADDRESS (address, required): ERC20Gateway contract address
/// - TOKEN_ADDRESS   (address, required): ERC20 token to deposit (origin token)
/// - RECIPIENT       (address, required): destination-chain recipient
/// - AMOUNT          (uint256, required): token amount (in token units)
contract DepositTokens is Script {
    function run() external {
        address gatewayAddress = vm.envAddress("GATEWAY_ADDRESS");
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        address recipient = vm.envAddress("RECIPIENT");
        uint256 amount = vm.envOr("AMOUNT", uint256(0));
        require(amount > 0, "AMOUNT must be > 0");

        ERC20Gateway gateway = ERC20Gateway(payable(gatewayAddress));
        IERC20 token = IERC20(tokenAddress);

        vm.startBroadcast();
        token.approve(gatewayAddress, amount);
        gateway.sendTokens(tokenAddress, recipient, amount);
        vm.stopBroadcast();
    }
}
