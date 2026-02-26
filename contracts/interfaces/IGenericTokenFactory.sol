// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IGenericTokenFactory
 * @author Fluent Labs
 * @notice Single interface for all token factories (ERC20 pegged, Universal, etc.)
 * @dev Two external functions only. Use keyData + deployArgs so different factory types share one interface:
 *      - ERC20/gateway: keyData = abi.encode(gateway, originToken), deployArgs = ""
 *      - Universal: keyData = abi.encode(l1Token, chainId), deployArgs = abi.encode(name, symbol, decimals, initialSupply, minter, pauser)
 */
interface IGenericTokenFactory {
    /// @custom:storage-location erc7201:fluent.storage.GenericTokenFactoryStorage
    struct GenericTokenFactoryStorage {
        mapping(address => address) bridgedTokens;
        mapping(address => TokenInfo) tokenInfo;
        uint256[50] __gap;
    }

    /// @notice Token deployment information
    struct TokenInfo {
        address l1Token;
        uint256 chainId;
        bool deployed;
    }

    event TokenDeployed(
        address indexed tokenAddress,
        address indexed originToken,
        string name,
        string symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    );

    /// @notice Emitted when a new bridged token is deployed (generic: address + keyData)
    event TokenDeployed(address indexed tokenAddress, bytes keyData);

    /**
     * @notice Computes the address of a bridged/pegged token
     * @param keyData Factory-specific key (e.g. abi.encode(gateway, originToken) or abi.encode(l1Token, chainId))
     * @param deployArgs Optional deployment params (empty for ERC20; for Universal: name, symbol, decimals, initialSupply, minter, pauser)
     * @return Predicted token address
     */
    function computeTokenAddress(bytes calldata keyData, bytes calldata deployArgs) external view returns (address);

    /**
     * @notice Deploys a bridged/pegged token
     * @param keyData Factory-specific key (same encoding as computeTokenAddress)
     * @param deployArgs Optional deployment params (empty for ERC20; for Universal: name, symbol, decimals, initialSupply, minter, pauser)
     * @return Address of the deployed token
     */
    function deployToken(bytes calldata keyData, bytes calldata deployArgs) external returns (address);
}
