// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title IERC20GatewayErrors
 * @dev Custom errors for the ERC20 gateway.
 */
interface IERC20GatewayErrors {
    /**
     * @notice Thrown when the token is not found.
     * @dev selector: 0xcbdb7b30
     */
    error TokenNotFound();

    /**
     * @notice Thrown when the origin token is zero.
     * @dev selector: 0x690be5f9
     */
    error OriginTokenZero();

    /**
     * @notice Thrown when the pegged token is wrong.
     * @dev selector: 0x164f4f0e
     */
    error WrongPeggedToken();

    /**
     * @notice Thrown when the token mapping check failed.
     * @dev selector: 0xc0260b4c
     */
    error TokenMappingCheckFailed();
}

/**
 * @title IERC20Gateway
 * @dev ERC20 token bridging: send, receive, deploy pegged tokens, and address computation.
 */
interface IERC20Gateway is IERC20GatewayErrors {
    /**
     * @notice Bridges ERC20 tokens to the remote chain and starts cross-chain delivery.
     * @dev Callable by anyone. Nonreentrant guard prevents callbacks from token hooks re-entering.
     *
     * @dev Round-trip flow:
     *      1) L1 -> L2 (deposit): caller sends an L1 origin token; gateway escrows tokens locally and bridge
     *         message triggers `receivePeggedTokens` on L2, minting/unlocking pegged tokens for `_to`.
     *      2) L2 -> L1 (withdraw): caller sends the L2 pegged token; gateway burns pegged tokens and bridge
     *         message triggers `receiveOriginTokens` on L1, releasing origin tokens for `_to`.
     *
     * @param token Token being bridged from the current chain (origin on deposit path, pegged on withdraw path).
     * @param to Recipient address on the destination chain.
     * @param amount Amount of tokens to bridge.
     */
    function sendTokens(address token, address to, uint256 amount) external payable;

    /**
     * @notice Receives tokens from the other side. Used on L1 to receive origin tokens from the other side.
     *
     * @param originToken The address of the origin token.
     * @param from The address of the sender on the other side.
     * @param to The address of the recipient on the local side.
     * @param amount The amount of tokens to receive.
     */
    function receiveOriginTokens(address originToken, address from, address to, uint256 amount) external;

    /**
     * @notice Receives pegged tokens from the other side. Used on L2 to receive pegged tokens from the other side.
     *
     * @param originToken The address of the origin token.
     * @param token The address of the token.
     * @param from The address of the sender on the other side.
     * @param to The address of the recipient on the local side.
     * @param amount The amount of tokens to receive.
     * @param tokenMetadata The metadata of the token (symbol, name, decimals)
     */
    function receivePeggedTokens(
        address originToken,
        address token,
        address from,
        address to,
        uint256 amount,
        bytes calldata tokenMetadata
    ) external;

    /**
     * @notice Computes the address of a pegged token for a given token for the other side.
     * @param gateway The address of the gateway to compute the pegged token address for.
     * @param originToken The address of the origin token to compute the pegged token address for.
     * @return The address of the pegged token.
     */
    function computeOtherSidePeggedTokenAddress(address gateway, address originToken) external view returns (address);

    /**
     * @notice Computes the local token address for a given origin token.
     * @param originToken The origin token address used for local CREATE2 prediction.
     * @return The address of the token.
     */
    function computeTokenAddress(address gateway, address originToken) external view returns (address);

    /**
     * @notice Returns the token mapping for a given key.
     * @param key The key to get the token mapping for.
     * @return The address of the token mapping.
     */
    function getTokenMapping(address key) external view returns (address);

    /**
     * @notice Returns the token factory.
     * @return The address of the token factory.
     */
    function getTokenFactory() external view returns (address);
}
