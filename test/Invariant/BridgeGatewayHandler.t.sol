// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {FluentBridge} from "../../contracts/bridge/FluentBridge.sol";
import {PaymentGateway} from "../../contracts/gateways/PaymentGateway.sol";
import {MockERC20Token} from "../../contracts/mocks/MockERC20.sol";

contract BridgeGatewayHandler is Test {
    FluentBridge internal immutable bridge;
    PaymentGateway internal immutable gateway;
    MockERC20Token internal immutable originToken;
    address internal immutable relayer;
    address internal immutable remoteGateway;
    address internal immutable user;

    uint256 internal sourceChainId;
    uint256 internal nextSourceBlock = 1;

    constructor(
        FluentBridge _bridge,
        PaymentGateway _gateway,
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

    function sendNative(uint96 rawAmount, address to) external {
        uint256 amount = bound(uint256(rawAmount), 1, 5 ether);
        address recipient = to == address(0) ? address(0xBEEF) : to;

        vm.deal(user, amount);
        vm.prank(user);
        gateway.sendNativeTokens{value: amount}(recipient, amount);
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

        address predictedPegged = gateway.computePeggedTokenAddress(address(originToken));
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock Token", uint8(18));
        bytes memory message = abi.encodeCall(
            PaymentGateway.receivePeggedTokens,
            (address(originToken), predictedPegged, user, recipient, amount, tokenMetadata)
        );

        uint256 nonce = bridge.receivedNonce();
        uint256 blockNumber = nextSourceBlock++;
        vm.prank(relayer);
        bridge.receiveMessage(remoteGateway, address(gateway), 0, sourceChainId, blockNumber, nonce, message);
    }
}
