// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

interface IERC721GatewayErrors {
    error OriginTokenZero();
    error WrongPeggedToken();
    error TokenMappingCheckFailed();
    error InvalidArrayLength();
}

interface IERC721Gateway is IERC721GatewayErrors {
    function sendToken(address token, address to, uint256 tokenId) external payable;

    function receivePeggedToken(
        address originToken,
        address peggedToken,
        address from,
        address to,
        uint256 tokenId,
        bytes calldata tokenMetadata
    ) external;

    function receiveOriginToken(address originToken, address from, address to, uint256 tokenId) external;

    function computeOtherSidePeggedTokenAddress(address gateway, address originToken) external view returns (address);

    function computeTokenAddress(address gateway, address originToken) external view returns (address);

    function getTokenMapping(address peggedToken) external view returns (address);

    function getTokenFactory() external view returns (address);
}
