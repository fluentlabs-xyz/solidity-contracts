// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IERC20Gateway {
    /**
     * @notice Sends tokens to the other side.
     * @param _token The address of the token to send.
     * @param _to The address of the recipient on the other side.
     * @param _amount The amount of tokens to send.
     */
    function sendTokens(address _token, address _to, uint256 _amount) external;

    /**
     * @notice Receives tokens from the other side.
     * @param _originToken The address of the origin token.
     * @param _from The address of the sender on the other side.
     * @param _to The address of the recipient on the local side.
     * @param _amount The amount of tokens to receive.
     */
    function receiveOriginTokens(address _originToken, address _from, address _to, uint256 _amount) external payable;

    /**
     * @notice Receives pegged tokens from the other side.
     * @param _originToken The address of the origin token.
     * @param _peggedToken The address of the pegged token.
     * @param _from The address of the sender on the other side.
     * @param _to The address of the recipient on the local side.
     * @param _amount The amount of tokens to receive.
     * @param _tokenMetadata The metadata of the token (symbol, name, decimals)
     */
    function receivePeggedTokens(
        address _originToken,
        address _peggedToken,
        address _from,
        address _to,
        uint256 _amount,
        bytes calldata _tokenMetadata
    ) external payable;

    /**
     * @notice Computes the address of a pegged token for a given token for the other side.
     * @param _token The address of the token to compute the pegged token address for.
     * @return The address of the pegged token.
     */
    function computeOtherSidePeggedTokenAddress(address _token) external view returns (address);

    /**
     * @notice Computes the local pegged token address for a given origin token.
     * @param _originToken The origin token address used for local CREATE2 prediction.
     * @return The address of the pegged token.
     */
    function computePeggedTokenAddress(address _originToken) external view returns (address);
}
