// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

interface IERC1155GatewayErrors {
    error OriginTokenZero();
    error WrongPeggedToken();
    error TokenMappingCheckFailed();
    error ArrayLengthMismatch();
}

interface IERC1155Gateway is IERC1155GatewayErrors {
    function sendToken(address token, address to, uint256 id, uint256 amount) external payable;

    function sendBatchTokens(address token, address to, uint256[] calldata ids, uint256[] calldata amounts)
        external
        payable;

    function receiveOriginTokens(address originToken, address from, address to, uint256 id, uint256 amount) external;

    function receiveOriginBatchTokens(
        address originToken,
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external;

    function receivePeggedTokens(
        address originToken,
        address peggedToken,
        address from,
        address to,
        uint256 id,
        uint256 amount,
        string calldata uri
    ) external;

    function receivePeggedBatchTokens(
        address originToken,
        address peggedToken,
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        string[] calldata uris
    ) external;

    function computeOtherSidePeggedTokenAddress(address gateway, address originToken) external view returns (address);

    function computeTokenAddress(address gateway, address originToken) external view returns (address);

    function getTokenMapping(address peggedToken) external view returns (address);

    function getTokenFactory() external view returns (address);
}
