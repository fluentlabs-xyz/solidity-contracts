// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title IERC721GatewayErrors
 * @dev Custom errors for the ERC721 gateway.
 */
interface IERC721GatewayErrors {
    /// @notice Thrown when the origin token is zero.
    error OriginTokenZero();

    /// @notice Thrown when the predicted pegged collection address does not match deployment.
    error WrongPeggedToken();

    /// @notice Thrown when the pegged-to-origin mapping does not match the message.
    error TokenMappingCheckFailed();

    /// @notice Thrown when `originToken` is excluded from this gateway.
    error BridgingExcludedOriginToken(address originToken);

    /// @notice Escrow release attempted but this gateway does not hold the NFT.
    error GatewayDoesNotHoldToken();
}

/**
 * @title IERC721GatewayEvents
 */
interface IERC721GatewayEvents {
    /// @notice Emitted when an NFT is received from the other chain.
    event ReceivedNFT(address indexed source, address indexed target, uint256 indexed tokenId);
}

/**
 * @title IERC721Gateway
 * @notice ERC721 bridging: escrow origin NFTs, mint/burn pegged collections, symmetric receive paths.
 */
interface IERC721Gateway is IERC721GatewayErrors, IERC721GatewayEvents {
    /**
     * @notice Bridges one ERC721 `tokenId` to the remote chain.
     * @param token Origin collection on deposit path, pegged collection on withdraw path.
     * @param to Recipient on the destination chain.
     * @param tokenId The NFT id to bridge.
     */
    function sendToken(address token, address to, uint256 tokenId) external payable;

    /**
     * @notice Releases an escrowed origin NFT (L1 path after pegged burn on L2).
     */
    function receiveOriginToken(address originToken, address from, address to, uint256 tokenId) external;

    /**
     * @notice Mints a pegged NFT (L2 path after origin escrow on L1).
     * @param tokenMetadata ABI-encoded `(string name, string symbol, string tokenURI)` from the source chain.
     */
    function receivePeggedToken(
        address originToken,
        address peggedToken,
        address from,
        address to,
        uint256 tokenId,
        bytes calldata tokenMetadata
    ) external;

    function computeOtherSidePeggedTokenAddress(address gateway, address originToken) external view returns (address);

    function computeTokenAddress(address gateway, address originToken) external view returns (address);

    function getTokenMapping(address peggedToken) external view returns (address);

    function getTokenFactory() external view returns (address);

    function getOtherSideTokenImplementation() external view returns (address);

    function getOtherSideFactory() external view returns (address);

    function getOtherSideBeacon() external view returns (address);

    function isBridgingExcludedOrigin(address originToken) external view returns (bool);

    function setBridgingExcludedOrigin(address originToken, bool excluded) external;

    function setTokenFactory(address tokenFactory) external;

    function setOtherSideTokenImplementation(address otherSideTokenImplementation) external;

    function setOtherSide(
        address otherSideGateway,
        uint256 otherSideChainId,
        address otherSideTokenImplementation,
        address otherSideFactory,
        address otherSideBeacon
    ) external;
}
