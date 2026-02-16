// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IUniversalToken} from "../interfaces/IUniversalToken.sol";
import {UniversalTokenSDK} from "../libraries/UniversalTokenSDK.sol";

/**
 * @title MockUniversalTokenPrecompile
 * @notice Mock implementation of the Fluent Universal Token precompile for Hardhat testing
 * @dev This contract simulates the precompile behavior by handling CREATE2 deployments
 *      with magic bytes and routing token calls to the appropriate token instance
 */
contract MockUniversalTokenPrecompile {
    using UniversalTokenSDK for *;

    /// @notice Token instance data
    struct TokenInstance {
        string name;
        string symbol;
        uint8 decimals;
        uint256 totalSupply;
        address minter;
        address pauser;
        bool paused;
        mapping(address => uint256) balances;
        mapping(address => mapping(address => uint256)) allowances;
        bool initialized;
    }

    /// @notice Mapping from token address to token instance
    mapping(address => TokenInstance) private tokens;

    /// @notice Events matching IUniversalToken
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    /**
     * @notice Handles CREATE2 deployment with magic bytes
     * @dev When CREATE2 is called with magic bytes, this contract initializes a token instance
     */
    function initializeToken(
        address tokenAddress,
        bytes32 nameBytes,
        bytes32 symbolBytes,
        uint8 decimals_,
        uint256 initialSupply,
        address minter,
        address pauser
    ) external {
        require(!tokens[tokenAddress].initialized, "Token already initialized");

        TokenInstance storage token = tokens[tokenAddress];
        token.name = _bytes32ToString(nameBytes);
        token.symbol = _bytes32ToString(symbolBytes);
        token.decimals = decimals_;
        token.minter = minter;
        token.pauser = pauser;
        token.paused = false;
        token.initialized = true;

        if (initialSupply > 0) {
            token.totalSupply = initialSupply;
            token.balances[msg.sender] = initialSupply;
            emit Transfer(address(0), msg.sender, initialSupply);
        }
    }

    /**
     * @notice Returns the name of the token
     */
    function name(address tokenAddress) external view returns (string memory) {
        require(tokens[tokenAddress].initialized, "Token not initialized");
        return tokens[tokenAddress].name;
    }

    /**
     * @notice Returns the symbol of the token
     */
    function symbol(
        address tokenAddress
    ) external view returns (string memory) {
        require(tokens[tokenAddress].initialized, "Token not initialized");
        return tokens[tokenAddress].symbol;
    }

    /**
     * @notice Returns the decimals of the token
     */
    function decimals(address tokenAddress) external view returns (uint8) {
        require(tokens[tokenAddress].initialized, "Token not initialized");
        return tokens[tokenAddress].decimals;
    }

    /**
     * @notice Returns the total supply of the token
     */
    function totalSupply(address tokenAddress) external view returns (uint256) {
        require(tokens[tokenAddress].initialized, "Token not initialized");
        return tokens[tokenAddress].totalSupply;
    }

    /**
     * @notice Returns the balance of an account
     */
    function balanceOf(
        address tokenAddress,
        address account
    ) external view returns (uint256) {
        require(tokens[tokenAddress].initialized, "Token not initialized");
        return tokens[tokenAddress].balances[account];
    }

    /**
     * @notice Transfers tokens (called via delegatecall or fallback)
     */
    function transfer(
        address tokenAddress,
        address to,
        uint256 amount
    ) external returns (bool) {
        TokenInstance storage token = tokens[tokenAddress];
        require(token.initialized, "Token not initialized");
        require(!token.paused, "Token is paused");
        require(to != address(0), "Invalid receiver");

        uint256 fromBalance = token.balances[msg.sender];
        require(fromBalance >= amount, "Insufficient balance");

        unchecked {
            token.balances[msg.sender] = fromBalance - amount;
            token.balances[to] += amount;
        }

        emit Transfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice Approves a spender
     */
    function approve(
        address tokenAddress,
        address spender,
        uint256 amount
    ) external returns (bool) {
        TokenInstance storage token = tokens[tokenAddress];
        require(token.initialized, "Token not initialized");

        token.allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Returns the allowance
     */
    function allowance(
        address tokenAddress,
        address owner,
        address spender
    ) external view returns (uint256) {
        require(tokens[tokenAddress].initialized, "Token not initialized");
        return tokens[tokenAddress].allowances[owner][spender];
    }

    /**
     * @notice Mints tokens
     */
    function mint(
        address tokenAddress,
        address to,
        uint256 amount
    ) external returns (bool) {
        TokenInstance storage token = tokens[tokenAddress];
        require(token.initialized, "Token not initialized");
        require(msg.sender == token.minter, "Not minter");
        require(!token.paused, "Token is paused");

        token.totalSupply += amount;
        unchecked {
            token.balances[to] += amount;
        }

        emit Transfer(address(0), to, amount);
        return true;
    }

    /**
     * @notice Pauses the token
     */
    function pause(address tokenAddress) external returns (bool) {
        TokenInstance storage token = tokens[tokenAddress];
        require(token.initialized, "Token not initialized");
        require(msg.sender == token.pauser, "Not pauser");
        require(!token.paused, "Already paused");

        token.paused = true;
        emit Paused(tokenAddress);
        return true;
    }

    /**
     * @notice Unpauses the token
     */
    function unpause(address tokenAddress) external returns (bool) {
        TokenInstance storage token = tokens[tokenAddress];
        require(token.initialized, "Token not initialized");
        require(msg.sender == token.pauser, "Not pauser");
        require(token.paused, "Not paused");

        token.paused = false;
        emit Unpaused(tokenAddress);
        return true;
    }

    /**
     * @notice Helper to convert bytes32 to string
     */
    function _bytes32ToString(
        bytes32 _bytes32
    ) private pure returns (string memory) {
        uint8 i = 0;
        while (i < 32 && _bytes32[i] != 0) {
            i++;
        }
        bytes memory bytesArray = new bytes(i);
        for (i = 0; i < 32 && _bytes32[i] != 0; i++) {
            bytesArray[i] = _bytes32[i];
        }
        return string(bytesArray);
    }
}
