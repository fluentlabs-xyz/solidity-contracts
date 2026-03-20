// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {BridgeGatewayBase} from "../Bridge/Base.t.sol";

contract ERC20GatewayTest is BridgeGatewayBase {
    function setUp() public override {
        super.setUp();
        _deployBridge(0);
        _deployGatewayStack();
    }

    function test_receivePeggedTokens_viaBridge_deploysAndMints() public {
        uint256 amount = 5 ether;
        address predictedPegged = _predictedPegged();
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock Token", uint8(18));
        bytes memory message = abi.encodeCall(
            ERC20Gateway.receivePeggedTokens,
            (address(originToken), predictedPegged, user, recipient, amount, tokenMetadata)
        );

        _relayMessage(remoteGateway, address(gateway), 0, message);

        assertEq(gateway.getTokenMapping(predictedPegged), address(originToken));
        assertEq(ERC20PeggedToken(predictedPegged).balanceOf(recipient), amount);
    }

    function test_sendTokens_originPath_locksOnGateway() public {
        uint256 amount = 3 ether;
        vm.prank(user);
        originToken.approve(address(gateway), amount);

        vm.prank(user);
        gateway.sendTokens(address(originToken), recipient, amount);

        assertEq(originToken.balanceOf(address(gateway)), amount);
    }

    function test_sendTokens_peggedPath_burnsSupply() public {
        address predictedPegged = _predictedPegged();
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock Token", uint8(18));
        bytes memory message = abi.encodeCall(
            ERC20Gateway.receivePeggedTokens,
            (address(originToken), predictedPegged, user, user, 10 ether, tokenMetadata)
        );
        _relayMessage(remoteGateway, address(gateway), 0, message);

        ERC20PeggedToken pegged = ERC20PeggedToken(predictedPegged);
        vm.prank(user);
        pegged.approve(address(gateway), 4 ether);

        uint256 supplyBefore = pegged.totalSupply();
        vm.prank(user);
        gateway.sendTokens(predictedPegged, recipient, 4 ether);

        assertEq(pegged.totalSupply(), supplyBefore - 4 ether);
    }

    function test_receiveOriginTokens_withZeroRecipient_marksFailed() public {
        bytes memory message = abi.encodeCall(ERC20Gateway.receiveOriginTokens, (address(originToken), user, address(0), 1 ether));
        (bytes32 messageHash, , ) = _relayMessage(remoteGateway, address(gateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }
}
