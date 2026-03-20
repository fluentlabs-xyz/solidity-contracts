// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {IGatewayErrors} from "../../contracts/interfaces/gateways/IGateway.sol";
import {IERC20GatewayErrors} from "../../contracts/interfaces/gateways/IERC20Gateway.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {MockERC20Token} from "../../contracts/mocks/MockERC20.sol";
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

    function test_sendTokens_revertsForZeroRecipient() public {
        vm.prank(user);
        vm.expectRevert(IGatewayErrors.InvalidRecipient.selector);
        gateway.sendTokens(address(originToken), address(0), 1 ether);
    }

    function test_receivePeggedTokens_directCall_revertsOnlyFluentBridge() public {
        address predictedPegged = _predictedPegged();
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock Token", uint8(18));

        vm.prank(user);
        vm.expectRevert(IGatewayErrors.OnlyFluentBridge.selector);
        gateway.receivePeggedTokens(address(originToken), predictedPegged, user, recipient, 1 ether, tokenMetadata);
    }

    function test_receivePeggedTokens_wrongGatewaySender_marksFailed() public {
        address predictedPegged = _predictedPegged();
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock Token", uint8(18));
        bytes memory message = abi.encodeCall(
            ERC20Gateway.receivePeggedTokens,
            (address(originToken), predictedPegged, user, recipient, 1 ether, tokenMetadata)
        );

        (bytes32 messageHash, , ) = _relayMessage(makeAddr("wrong-remote-gateway"), address(gateway), 0, message);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_receivePeggedTokens_wrongPredictedPeggedToken_marksFailed() public {
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock Token", uint8(18));
        bytes memory message = abi.encodeCall(
            ERC20Gateway.receivePeggedTokens,
            (address(originToken), makeAddr("wrong-pegged-token"), user, recipient, 1 ether, tokenMetadata)
        );

        (bytes32 messageHash, , ) = _relayMessage(remoteGateway, address(gateway), 0, message);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_receivePeggedTokens_existingPeggedWrongMapping_marksFailed() public {
        address predictedPegged = _predictedPegged();
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock Token", uint8(18));

        bytes memory firstMessage = abi.encodeCall(
            ERC20Gateway.receivePeggedTokens,
            (address(originToken), predictedPegged, user, recipient, 1 ether, tokenMetadata)
        );
        _relayMessage(remoteGateway, address(gateway), 0, firstMessage);

        MockERC20Token otherOrigin = new MockERC20Token("OTHER", "OTH", 1_000 ether, user);
        bytes memory secondMessage = abi.encodeCall(
            ERC20Gateway.receivePeggedTokens,
            (address(otherOrigin), predictedPegged, user, recipient, 1 ether, tokenMetadata)
        );
        (bytes32 messageHash, , ) = _relayMessage(remoteGateway, address(gateway), 0, secondMessage);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_receiveOriginTokens_wrongGatewaySender_marksFailed() public {
        bytes memory message = abi.encodeCall(ERC20Gateway.receiveOriginTokens, (address(originToken), user, recipient, 1 ether));
        (bytes32 messageHash, , ) = _relayMessage(makeAddr("wrong-remote-gateway"), address(gateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_receiveOriginTokens_originTokenZero_marksFailed() public {
        bytes memory message = abi.encodeCall(ERC20Gateway.receiveOriginTokens, (address(0), user, recipient, 1 ether));
        (bytes32 messageHash, , ) = _relayMessage(remoteGateway, address(gateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_receivePeggedTokens_originTokenZero_marksFailed() public {
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock Token", uint8(18));
        bytes memory message = abi.encodeCall(
            ERC20Gateway.receivePeggedTokens,
            (address(0), _predictedPegged(), user, recipient, 1 ether, tokenMetadata)
        );
        (bytes32 messageHash, , ) = _relayMessage(remoteGateway, address(gateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_setOtherSideL2_andComputeOtherSidePeggedTokenAddress_universalPath() public {
        address remoteFactory = makeAddr("remote-universal-factory");
        address remoteImplementation = makeAddr("remote-implementation");

        vm.prank(admin);
        gateway.setOtherSideL2(remoteGateway, remoteImplementation, remoteFactory, sourceChainId);

        assertEq(gateway.getOtherSideBeacon(), address(0));
        assertEq(gateway.getOtherSideChainId(), sourceChainId);
        assertEq(gateway.getOtherSideFactory(), remoteFactory);
        assertEq(gateway.getOtherSideTokenImplementation(), remoteImplementation);

        address computed = gateway.computeOtherSidePeggedTokenAddress(address(originToken));
        assertTrue(computed != address(0));
    }

    function test_setOtherSideL2_revertsOnZeroChainId() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IGatewayErrors.ZeroAddressNotAllowed.selector, "setOtherSideL2 parameters"));
        gateway.setOtherSideL2(remoteGateway, makeAddr("impl"), makeAddr("factory"), 0);
    }
}
