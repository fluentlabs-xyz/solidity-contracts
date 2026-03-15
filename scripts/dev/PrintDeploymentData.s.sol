// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {UniversalTokenSDK} from "../../contracts/libraries/UniversalTokenSDK.sol";

/// @notice Prints UniversalTokenSDK deployment data and its hash via an event.
/// @dev Environment (all optional, with sensible defaults):
/// - TOKEN_NAME           (string, default: "Bridged Token")
/// - TOKEN_SYMBOL         (string, default: "BRIDGE")
/// - TOKEN_DECIMALS       (uint256, default: 18)
/// - TOKEN_INITIAL_SUPPLY (uint256, default: 100)
/// - MINTER               (address, default: address(0))
/// - PAUSER               (address, default: address(0))
contract PrintDeploymentData is Script {
    event DeploymentData(bytes deploymentData, bytes32 bytecodeHash);

    function run() external {
        string memory name = vm.envOr("TOKEN_NAME", string("Bridged Token"));
        string memory symbol = vm.envOr("TOKEN_SYMBOL", string("BRIDGE"));
        uint256 decimals = vm.envOr("TOKEN_DECIMALS", uint256(18));
        uint256 initialSupply = vm.envOr("TOKEN_INITIAL_SUPPLY", uint256(100));
        address minter = vm.envOr("MINTER", address(0));
        address pauser = vm.envOr("PAUSER", address(0));

        bytes memory deploymentData = UniversalTokenSDK.createDeploymentData(name, symbol, uint8(decimals), initialSupply, minter, pauser);
        bytes32 hash = keccak256(deploymentData);

        emit DeploymentData(deploymentData, hash);
    }
}
