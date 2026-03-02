// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IGenericTokenFactoryErrors {
    /// @dev Thrown when the gateway is invalid.
    /// @dev selector: 0xfc9dfe85
    error InvalidGateway();
    /// @dev Thrown when the origin token is invalid.
    /// @dev selector: 0x0e695881
    error InvalidOriginToken();
    /// @dev Thrown when the token is already deployed.
    /// @dev selector: 0x6474d0da
    error TokenAlreadyDeployed();
    /// @dev Thrown when the chain ID is invalid.
    /// @dev selector: 0x7a47c9a2
    error InvalidChainId();
    /// @dev Thrown when the chain ID is not the same as the block chain ID.
    /// @dev selector: 0x5f87bc00
    error WrongChainId();
    /// @dev Thrown when the implementation address is zero.
    /// @dev selector: 0xd02c623d
    error ZeroImplementationAddress();
}

/**
 * @title IGenericTokenFactory
 * @author Fluent Labs
 * @notice Single interface for all token factories (ERC20 pegged, Universal, etc.)
 * @dev Two external functions only. Use keyData + deployArgs so different factory types share one interface:
 *      - ERC20/gateway: keyData = abi.encode(gateway, originToken), deployArgs = ""
 *      - Universal: keyData = abi.encode(originToken, chainId), deployArgs = abi.encode(name, symbol, decimals, initialSupply, minter, pauser)
 */
interface IGenericTokenFactory is IGenericTokenFactoryErrors {
    /**
     * @notice Emitted when a token is deployed
     * @param originToken The origin token address
     * @param peggedToken The pegged token address
     */
    event TokenDeployed(address indexed originToken, address indexed peggedToken);

    /// @custom:storage-location erc7201:fluent.storage.GenericTokenFactoryStorage
    struct GenericTokenFactoryStorage {
        mapping(address => address) bridgedTokens;
        mapping(address => TokenInfo) tokenInfo;
        uint256[50] __gap;
    }

    /// @notice Token deployment information
    struct TokenInfo {
        address originToken;
        uint256 chainId;
        bool deployed;
    }

    /**
     * @notice Computes the address of a bridged/pegged token
     * @param keyData Factory-specific key (e.g. abi.encode(gateway, originToken) or abi.encode(originToken, chainId))
     * @param deployArgs Optional deployment params (empty for ERC20; for Universal: name, symbol, decimals, initialSupply, minter, pauser)
     * @return Predicted token address
     */
    function computeTokenAddress(bytes calldata keyData, bytes calldata deployArgs) external view returns (address);

    /**
     * @notice Alias of computeTokenAddress for compatibility with pegged-token naming.
     * @param keyData Factory-specific key (e.g. abi.encode(gateway, originToken) or abi.encode(originToken, chainId))
     * @param deployArgs Optional deployment params (empty for ERC20; for Universal: name, symbol, decimals, initialSupply, minter, pauser)
     * @return Predicted pegged token address
     */
    function computePeggedTokenAddress(bytes calldata keyData, bytes calldata deployArgs) external view returns (address);

    /**
     * @notice Deploys a bridged/pegged token
     * @param keyData Factory-specific key (same encoding as computeTokenAddress)
     * @param deployArgs Optional deployment params (empty for ERC20; for Universal: name, symbol, decimals, initialSupply, minter, pauser)
     * @return Address of the deployed token
     */
    function deployToken(bytes calldata keyData, bytes calldata deployArgs) external returns (address);
}
