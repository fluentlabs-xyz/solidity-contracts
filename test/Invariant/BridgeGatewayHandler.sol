// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {MockERC20Token} from "../../test/mocks/MockERC20.sol";

contract BridgeGatewayHandler is Test {
    IFluentBridge internal immutable bridge;
    ERC20Gateway internal immutable gateway;
    MockERC20Token internal immutable originToken;
    address internal immutable relayer;
    address internal immutable remoteGateway;
    address internal immutable user;

    uint256 internal sourceChainId;
    uint256 internal nextSourceBlock = 1;

    constructor(
        IFluentBridge _bridge,
        ERC20Gateway _gateway,
        MockERC20Token _originToken,
        address _relayer,
        address _remoteGateway,
        address _user
    ) {
        bridge = _bridge;
        gateway = _gateway;
        originToken = _originToken;
        relayer = _relayer;
        remoteGateway = _remoteGateway;
        user = _user;
        sourceChainId = block.chainid + 1;
    }

    function sendOrigin(uint96 rawAmount, address to) external {
        uint256 amount = bound(uint256(rawAmount), 1, 100 ether);
        address recipient = to == address(0) ? address(0xBEEF) : to;

        vm.prank(user);
        originToken.approve(address(gateway), amount);
        vm.prank(user);
        gateway.sendTokens(address(originToken), recipient, amount);
    }

    function receivePegged(uint96 rawAmount, address to) external {
        uint256 amount = bound(uint256(rawAmount), 1, 100 ether);
        address recipient = to == address(0) ? address(0xBEEF) : to;

        address predictedPegged = gateway.computeTokenAddress(address(gateway), address(originToken));
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock Token", uint8(18));
        bytes memory message = abi.encodeCall(
            ERC20Gateway.receivePeggedTokens,
            (address(originToken), predictedPegged, user, recipient, amount, tokenMetadata)
        );

        uint256 nonce = bridge.getReceivedNonce();
        uint256 blockNumber = nextSourceBlock++;
        vm.prank(relayer);
        bridge.receiveMessage(remoteGateway, address(gateway), 0, sourceChainId, blockNumber, nonce, message);
    }
}
