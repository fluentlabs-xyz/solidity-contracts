// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {MockERC20Token} from "../../contracts/mocks/MockERC20.sol";

contract DeployMockERC20Token is Script {
    event MockERC20TokenDeployed(address indexed token, string name, string symbol, uint256 initialSupply, address recipient);

    function run() external returns (address tokenAddress) {
        string memory name = vm.envOr("MOCK_ERC20_NAME", string("Mock Deposit Token"));
        string memory symbol = vm.envOr("MOCK_ERC20_SYMBOL", string("MDT"));
        uint256 initialSupply = vm.envOr("MOCK_ERC20_SUPPLY", uint256(100_000_000 ether));

        address defaultRecipient = vm.envOr("INITIAL_OWNER", address(0));
        address recipient = vm.envOr("MOCK_ERC20_RECIPIENT", address(0));
        if (recipient == address(0)) {
            recipient = defaultRecipient;
        }
        require(recipient != address(0), "no recipient provided");

        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        vm.startBroadcast();
        MockERC20Token token = new MockERC20Token(name, symbol, initialSupply, recipient);
        vm.stopBroadcast();

        tokenAddress = address(token);
        emit MockERC20TokenDeployed(tokenAddress, name, symbol, initialSupply, recipient);

        if (bytes(outputPath).length != 0) {
            string memory json = vm.serializeAddress("deployment", "mock_erc20", tokenAddress);
            vm.writeJson(json, outputPath);
        }
    }
}
