// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PaymentGateway} from "../../contracts/gateways/PaymentGateway.sol";
import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {IGateway} from "../../contracts/interfaces/IGateway.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {BridgeGatewayBase, RejectEther} from "../Bridge/Base.t.sol";

contract PaymentGatewayTest is BridgeGatewayBase {
    function setUp() public override {
        super.setUp();
        _deployBridge(0);
        _deployGatewayStack();
    }

    function test_sendNativeTokens_locksNativeInBridge() public {
        uint256 amount = 1 ether;
        vm.deal(user, amount);

        vm.prank(user);
        gateway.sendNativeTokens{value: amount}(recipient, amount);

        assertEq(address(bridge).balance, amount);
    }

    function test_receivePeggedTokens_viaBridge_deploysAndMints() public {
        uint256 amount = 5 ether;
        address predictedPegged = _predictedPegged();
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock Token", uint8(18));
        bytes memory message = abi.encodeCall(
            PaymentGateway.receivePeggedTokens,
            (address(originToken), predictedPegged, user, recipient, amount, tokenMetadata)
        );

        _relayMessage(remoteGateway, address(gateway), 0, message);

        assertEq(gateway.tokenMapping(predictedPegged), address(originToken));
        assertEq(ERC20PeggedToken(predictedPegged).balanceOf(recipient), amount);
    }

    function test_receiveNativeTokens_withRejectingRecipient_marksFailed() public {
        RejectEther rejector = new RejectEther();
        bytes memory message = abi.encodeCall(PaymentGateway.receiveNativeTokens, (user, address(rejector), 1 ether));
        (bytes32 messageHash, , ) = _relayMessage(remoteGateway, address(gateway), 1 ether, message);

        assertEq(uint256(bridge.receivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_sendTokens_peggedTokenPath_burnsSupply() public {
        address predictedPegged = _predictedPegged();
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock Token", uint8(18));
        bytes memory message = abi.encodeCall(
            PaymentGateway.receivePeggedTokens,
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

    function test_updateTokenMapping_requiresExistingPeggedToken() public {
        vm.prank(admin);
        vm.expectRevert(bytes4(keccak256("UnknownPeggedToken()")));
        gateway.updateTokenMapping(address(originToken), makeAddr("unknownPegged"));
    }

    function test_updateTokenMapping_updatesKnownPeggedTokenOnly() public {
        address predictedPegged = _predictedPegged();
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock Token", uint8(18));
        bytes memory message = abi.encodeCall(
            PaymentGateway.receivePeggedTokens,
            (address(originToken), predictedPegged, user, recipient, 1 ether, tokenMetadata)
        );
        _relayMessage(remoteGateway, address(gateway), 0, message);

        address customOrigin = makeAddr("customOrigin");
        vm.prank(admin);
        gateway.updateTokenMapping(customOrigin, predictedPegged);

        assertEq(gateway.tokenMapping(predictedPegged), customOrigin);
    }

    function testFuzz_sendNativeTokens_locksExactAmount(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1, 5 ether);
        vm.deal(user, amount);

        vm.prank(user);
        gateway.sendNativeTokens{value: amount}(recipient, amount);

        assertEq(address(bridge).balance, amount);
    }
}
