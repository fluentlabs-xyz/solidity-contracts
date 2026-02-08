// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {UniversalTokenSDK} from "../libraries/UniversalTokenSDK.sol";
import {IUniversalToken} from "../interfaces/IUniversalToken.sol";
import {ITokenFactory} from "../interfaces/ITokenFactory.sol";
import {GenericTokenFactory} from "./GenericTokenFactory.sol";

/**
 * @title UniversalTokenFactory
 * @notice Factory contract for deploying Universal Tokens
 * @dev Provides deterministic token deployment for bridge integration
 *      Implements ITokenFactory interface to match ERC20TokenFactory pattern
 */
contract UniversalTokenFactory is GenericTokenFactory, ITokenFactory {
    using UniversalTokenSDK for *;

    /// @notice Error thrown when chainId is not set for a gateway+token pair
    error ChainIdNotSet(address gateway, address originToken);
    /// @notice Error thrown when token metadata is not set
    error TokenMetadataNotSet(address gateway, address originToken);

    /// @notice Mapping from (gateway, originToken) to chainId
    mapping(address => mapping(address => uint256)) public originChainIds;
    /// @notice Mapping from (gateway, originToken) to token metadata
    mapping(address => mapping(address => TokenMetadata)) public tokenMetadata;

    /// @notice Token metadata structure
    struct TokenMetadata {
        string name;
        string symbol;
        uint8 decimals;
        address minter;
        address pauser;
    }

    /**
     * @notice Sets token metadata for a gateway+token pair
     * @param _gateway Gateway address
     * @param _originToken Origin token address
     * @param _name Token name
     * @param _symbol Token symbol
     * @param _decimals Number of decimals
     * @param _minter Minter address
     * @param _pauser Pauser address
     */
    function setTokenMetadata(
        address _gateway,
        address _originToken,
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _minter,
        address _pauser
    ) external onlyOwner {
        tokenMetadata[_gateway][_originToken] = TokenMetadata({
            name: _name,
            symbol: _symbol,
            decimals: _decimals,
            minter: _minter,
            pauser: _pauser
        });
    }

    /**
     * @notice Computes the salt for a gateway+token pair
     * @param _gateway Gateway address (not used for Universal Tokens, but kept for interface compatibility)
     * @param _originToken Origin token address
     * @return salt Computed salt
     * @dev For Universal Tokens, salt is based on (originToken, chainId), not gateway
     */
    function _calculateSalt(
        address _gateway,
        address _originToken
    ) internal view returns (bytes32 salt) {
        uint256 chainId = originChainIds[_gateway][_originToken];
        if (chainId == 0) revert ChainIdNotSet(_gateway, _originToken);
        return UniversalTokenSDK.computeBridgeTokenSalt(_originToken, chainId);
    }

    /**
     * @notice Computes the address of a pegged token for a given gateway and origin token
     * @param _gateway Gateway address
     * @param _originToken Origin token address
     * @return Predicted pegged token address
     */
    function computePeggedTokenAddress(
        address _gateway,
        address _originToken
    ) external view override returns (address) {
        uint256 chainId = originChainIds[_gateway][_originToken];
        if (chainId == 0) revert ChainIdNotSet(_gateway, _originToken);
        return
            UniversalTokenSDK.computeBridgedTokenAddress(
                address(this),
                _originToken,
                chainId
            );
    }

    /**
     * @notice Computes the address of a pegged token on the other side
     * @param _gateway Other side gateway address
     * @param _originToken Origin token address
     * @param _implementation Token implementation address (not used for Universal Tokens)
     * @param _factory Factory address (not used for Universal Tokens)
     * @return Predicted pegged token address
     */
    function computeOtherSidePeggedTokenAddress(
        address _gateway,
        address _originToken,
        address _implementation,
        address _factory
    ) external view override returns (address) {
        // For Universal Tokens, the address is the same regardless of gateway
        // We use the factory address to compute, but need chainId
        uint256 chainId = originChainIds[_gateway][_originToken];
        if (chainId == 0) revert ChainIdNotSet(_gateway, _originToken);
        // Use the provided factory address (other side factory) instead of address(this)
        return
            UniversalTokenSDK.computeBridgedTokenAddress(
                _factory,
                _originToken,
                chainId
            );
    }

    /**
     * @notice Deploys a pegged token for a given gateway and origin token
     * @param _gateway Gateway address
     * @param _originToken Origin token address
     * @return Address of the deployed pegged token
     */
    function deployToken(
        address _gateway,
        address _originToken
    ) external override returns (address) {
        uint256 chainId = originChainIds[_gateway][_originToken];
        if (chainId == 0) revert ChainIdNotSet(_gateway, _originToken);

        TokenMetadata memory metadata = tokenMetadata[_gateway][_originToken];
        if (bytes(metadata.name).length == 0)
            revert TokenMetadataNotSet(_gateway, _originToken);

        // Compute deterministic address
        bytes32 salt = _calculateSalt(_gateway, _originToken);
        address predictedAddress = UniversalTokenSDK.computeBridgedTokenAddress(
            address(this),
            _originToken,
            chainId
        );

        // Check if already deployed
        if (predictedAddress.code.length != 0) {
            return predictedAddress;
        }

        // Deploy token with zero initial supply (will be minted by bridge)
        address tokenAddress = UniversalTokenSDK.deployToken(
            salt,
            metadata.name,
            metadata.symbol,
            metadata.decimals,
            0, // initialSupply
            metadata.minter,
            metadata.pauser
        );

        require(
            tokenAddress == predictedAddress,
            "UniversalTokenFactory: address mismatch"
        );

        // Record deployment
        bridgedTokens[_originToken] = tokenAddress;
        tokenInfo[tokenAddress] = TokenInfo({
            l1Token: _originToken,
            chainId: chainId,
            deployed: true
        });

        emit TokenDeployed(
            _originToken,
            tokenAddress,
            metadata.name,
            metadata.symbol,
            metadata.decimals
        );

        return tokenAddress;
    }
}
