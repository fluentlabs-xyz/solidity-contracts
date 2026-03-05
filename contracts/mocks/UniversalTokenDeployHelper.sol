// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {UniversalToken} from "../tokens/UniversalToken.sol";

/**
 * @title UniversalTokenDeployHelper
 * @notice Helper contract for deploying Universal Tokens with CREATE2 in tests
 * @dev This allows testing Universal Token deployment on Hardhat where the precompile doesn't exist
 */
contract UniversalTokenDeployHelper {
    /**
     * @notice Deploys a Universal Token using CREATE2
     * @param salt Salt for deterministic address
     * @param name Token name
     * @param symbol Token symbol
     * @param decimals Number of decimals
     * @param initialSupply Initial supply
     * @param minter Minter address
     * @param pauser Pauser address
     * @return tokenAddress Address of the deployed token
     */
    function deployToken(
        bytes32 salt,
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    ) external returns (address tokenAddress) {
        bytes memory bytecode = abi.encodePacked(
            type(UniversalToken).creationCode,
            abi.encode(name, symbol, decimals, initialSupply, minter, pauser)
        );

        assembly {
            tokenAddress := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }

        require(tokenAddress != address(0), "UniversalTokenDeployHelper: deployment failed");
    }
}
