// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

interface IERC1155GatewayErrors {
    error OriginTokenZero();
    error WrongPeggedToken();
    error TokenMappingCheckFailed();
    error InvalidArrayLength();
}

interface IERC1155Gateway is IERC1155GatewayErrors {
    function sendToken(address token, address to, uint256 id, uint256 amount, bytes calldata data) external payable;

    function sendBatch(
        address token,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external payable;

    function receivePeggedToken(
        address originToken,
        address peggedToken,
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data,
        bytes calldata tokenMetadata
    ) external;

    function receivePeggedBatch(
        address originToken,
        address peggedToken,
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data,
        bytes calldata tokenMetadata
    ) external;

    function receiveOriginToken(
        address originToken,
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external;

    function receiveOriginBatch(
        address originToken,
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external;

    function computeOtherSidePeggedTokenAddress(address gateway, address originToken) external view returns (address);

    function computeTokenAddress(address gateway, address originToken) external view returns (address);

    function getTokenMapping(address peggedToken) external view returns (address);

    function getTokenFactory() external view returns (address);
}
