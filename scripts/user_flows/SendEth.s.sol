// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";

/// @notice Sends ETH from the broadcasting account to a recipient.
/// @dev Environment:
/// - RECIPIENT (address, required): recipient of the transfer
/// - AMOUNT_WEI (uint256, optional): amount in wei (default: 0.01 ether)
contract SendEth is Script {
    function run() external {
        address recipient = vm.envAddress("RECIPIENT");
        uint256 amountWei = vm.envOr("AMOUNT_WEI", uint256(0.01 ether));
        require(recipient != address(0), "RECIPIENT is zero address");

        vm.startBroadcast();
        (bool ok, ) = payable(recipient).call{value: amountWei}("");
        require(ok, "ETH transfer failed");
        vm.stopBroadcast();
    }
}
