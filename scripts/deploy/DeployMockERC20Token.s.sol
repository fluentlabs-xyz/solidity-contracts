// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseScript} from "../Base.sol";
import {MockERC20Token} from "../../contracts/mocks/MockERC20.sol";

contract DeployMockERC20Token is BaseScript {
    event MockERC20TokenDeployed(address indexed token, string name, string symbol, uint256 initialSupply, address recipient);

    function run() external returns (address tokenAddress) {
        string memory name = vm.envOr("MOCK_ERC20_NAME", string("Mock Deposit Token"));
        string memory symbol = vm.envOr("MOCK_ERC20_SYMBOL", string("MDT"));
        uint256 initialSupply = vm.envOr("MOCK_ERC20_SUPPLY", uint256(100_000_000 ether));

        // Reuse INITIAL_OWNER when recipient is not explicitly set.
        address defaultRecipient = vm.envAddress("INITIAL_OWNER");
        address recipient = vm.envOr("MOCK_ERC20_RECIPIENT", defaultRecipient);

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
