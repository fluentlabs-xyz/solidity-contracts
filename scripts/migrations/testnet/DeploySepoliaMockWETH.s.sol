// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {MockWETH} from "../../../contracts/mocks/MockWETH.sol";

/// @notice One-shot deploy of {MockWETH} on Ethereum Sepolia (WETH9-shaped test double).
///
/// @dev Run (example):
///        forge script scripts/migrations/testnet/DeploySepoliaMockWETH.s.sol:DeploySepoliaMockWETH \
///          --rpc-url "$L1_RPC" --broadcast -vvvv
///
///      Then export the printed address for downstream migrations:
///        export SEPOLIA_MOCK_WETH=0x...
contract DeploySepoliaMockWETH is Script {
    function run() external {
        vm.startBroadcast();
        MockWETH weth = new MockWETH();
        vm.stopBroadcast();

        console2.log("MockWETH deployed at:", address(weth));
        console2.log("export L1_WETH_ADDRESS=", address(weth));
    }
}
