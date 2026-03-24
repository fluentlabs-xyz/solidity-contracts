// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";

/// @notice Burns pegged ERC20 on L2 via ERC20Gateway and sends a withdrawal message to L1.
/// @dev Environment:
/// - GATEWAY_ADDRESS      (address, required): L2 ERC20Gateway address
/// - ORIGIN_TOKEN_ADDRESS (address, required): L1 origin token address
/// - RECIPIENT_ADDRESS    (address, required): L1 recipient of the unlocked tokens
/// - AMOUNT               (uint256, required): amount to withdraw (in pegged token units)
contract WithdrawERC20FluentToSepolia is Script {
    function run() external {
        address gatewayAddress = vm.envAddress("GATEWAY_ADDRESS");
        address originToken = vm.envAddress("ORIGIN_TOKEN_ADDRESS");
        address recipient = vm.envAddress("RECIPIENT_ADDRESS");
        uint256 amount = vm.envOr("AMOUNT", uint256(0));
        require(gatewayAddress != address(0), "GATEWAY_ADDRESS is zero");
        require(originToken != address(0), "ORIGIN_TOKEN_ADDRESS is zero");
        require(recipient != address(0), "RECIPIENT_ADDRESS is zero");
        require(amount > 0, "AMOUNT must be > 0");

        ERC20Gateway gateway = ERC20Gateway(payable(gatewayAddress));
        address peggedToken = gateway.computeTokenAddress(gatewayAddress, originToken);
        require(peggedToken.code.length > 0, "pegged token is not deployed");

        vm.startBroadcast();
        gateway.sendTokens(peggedToken, recipient, amount);
        vm.stopBroadcast();
    }
}
