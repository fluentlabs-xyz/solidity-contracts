// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {FluentBridge} from "../../contracts/FluentBridge.sol";
import {IFluentBridge} from "../../contracts/interfaces/IFluentBridge.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";
import {GenericTokenFactory} from "../../contracts/factories/GenericTokenFactory.sol";
import {PaymentsGateway} from "../../contracts/gateways/PaymentsGateway.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {MockERC20Token} from "../../contracts/mocks/MockERC20.sol";
import {Vm} from "../Rollup/Base.t.sol";

contract RejectEther {
    receive() external payable {
        revert("reject-eth");
    }
}

contract PaymentsGatewayTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant USER = address(0x1111);
    address internal constant RECIPIENT = address(0x2222);
    address internal constant OTHER_SIDE_GATEWAY = address(0x3333);
    address internal constant WRONG_SIDE_GATEWAY = address(0x4444);

    FluentBridge internal bridge;
    ERC20TokenFactory internal factory;
    PaymentsGateway internal gateway;
    ERC20PeggedToken internal peggedImplementation;
    MockERC20Token internal originToken;

    function setUp() public {
        bridge = _deployBridge();
        peggedImplementation = new ERC20PeggedToken();
        factory = _deployFactory(address(peggedImplementation));
        gateway = _deployGateway(address(bridge), address(factory));

        // Gateway must own factory to deploy pegged tokens.
        factory.transferOwnership(address(gateway));
        gateway.acceptTokenFactory();

        gateway.setOtherSide(OTHER_SIDE_GATEWAY, address(peggedImplementation), address(factory), factory.beacon());

        originToken = new MockERC20Token("Mock", "MOCK", 1_000_000 ether, USER);
    }

    function test_sendTokens_originToken_locksFundsInGateway() public {
        uint256 amount = 10 ether;

        vm.prank(USER);
        originToken.approve(address(gateway), amount);

        uint256 gatewayBefore = originToken.balanceOf(address(gateway));
        vm.prank(USER);
        gateway.sendTokens(address(originToken), RECIPIENT, amount);

        uint256 gatewayAfter = originToken.balanceOf(address(gateway));
        assertEq(gatewayAfter, gatewayBefore + amount, "gateway should lock origin tokens");
    }

    function test_receivePeggedTokens_viaBridge_deploysAndMints() public {
        uint256 amount = 5 ether;
        address predictedPegged = gateway.computePeggedTokenAddress(address(originToken));
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock", uint8(18));
        bytes memory message = abi.encodeCall(
            PaymentsGateway.receivePeggedTokens,
            (address(originToken), predictedPegged, USER, RECIPIENT, amount, tokenMetadata)
        );

        bridge.receiveMessage(
            OTHER_SIDE_GATEWAY, address(gateway), 0, block.chainid + 1, 1, bridge.receivedNonce(), message
        );

        assertEq(gateway.tokenMapping(predictedPegged), address(originToken), "token mapping should be registered");
        assertEq(
            ERC20PeggedToken(predictedPegged).balanceOf(RECIPIENT), amount, "recipient should receive pegged tokens"
        );
    }

    function test_receiveOriginTokens_viaBridge_unlocksFunds() public {
        uint256 amount = 7 ether;

        vm.prank(USER);
        originToken.approve(address(gateway), amount);
        vm.prank(USER);
        gateway.sendTokens(address(originToken), USER, amount);

        uint256 recipientBefore = originToken.balanceOf(RECIPIENT);
        bytes memory message =
            abi.encodeCall(PaymentsGateway.receiveOriginTokens, (address(originToken), USER, RECIPIENT, amount));
        bridge.receiveMessage(
            OTHER_SIDE_GATEWAY, address(gateway), 0, block.chainid + 1, 2, bridge.receivedNonce(), message
        );

        assertEq(
            originToken.balanceOf(RECIPIENT),
            recipientBefore + amount,
            "recipient should receive unlocked origin tokens"
        );
    }

    function test_computeOtherSidePeggedTokenAddress_matchesFactoryComputation() public view {
        address fromGateway = gateway.computeOtherSidePeggedTokenAddress(address(originToken));
        bytes memory keyData = abi.encode(OTHER_SIDE_GATEWAY, address(originToken));
        address fromFactory = GenericTokenFactory(address(factory)).computeOtherSidePeggedTokenAddress(keyData, "");

        assertEq(fromGateway, fromFactory, "gateway/factory cross-side compute mismatch");
    }

    function test_receiveOriginTokens_withUnexpectedValue_marksMessageFailed() public {
        uint256 forwardedValue = 1;
        vm.deal(address(bridge), forwardedValue);

        uint256 nonce = bridge.receivedNonce();
        uint256 sourceChainId = block.chainid + 1;
        uint256 sourceBlock = 77;
        bytes memory message =
            abi.encodeCall(PaymentsGateway.receiveOriginTokens, (address(originToken), USER, RECIPIENT, 1));
        bytes32 messageHash = keccak256(
            abi.encode(OTHER_SIDE_GATEWAY, address(gateway), forwardedValue, sourceChainId, sourceBlock, nonce, message)
        );

        bridge.receiveMessage(
            OTHER_SIDE_GATEWAY, address(gateway), forwardedValue, sourceChainId, sourceBlock, nonce, message
        );

        assertEq(
            uint256(bridge.receivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "message should be marked failed"
        );
    }

    function test_sendNativeTokens_success_increasesBridgeBalance() public {
        uint256 amount = 1 ether;
        vm.deal(USER, amount);
        uint256 beforeBalance = address(bridge).balance;

        vm.prank(USER);
        gateway.sendNativeTokens{value: amount}(RECIPIENT, amount);

        assertEq(address(bridge).balance, beforeBalance + amount, "bridge balance should increase");
    }

    function test_sendNativeTokens_revertsOnInvalidRecipient() public {
        vm.deal(USER, 1 ether);
        vm.prank(USER);
        vm.expectRevert(bytes4(keccak256("InvalidRecipient()")));
        gateway.sendNativeTokens{value: 1}(address(0), 1);
    }

    function test_sendNativeTokens_revertsOnInvalidAmount() public {
        vm.deal(USER, 1 ether);
        vm.prank(USER);
        vm.expectRevert(bytes4(keccak256("InvalidNativeAmount()")));
        gateway.sendNativeTokens{value: 2}(RECIPIENT, 1);
    }

    function test_sendTokens_revertsOnInvalidRecipient() public {
        vm.prank(USER);
        vm.expectRevert(bytes4(keccak256("InvalidRecipient()")));
        gateway.sendTokens(address(originToken), address(0), 1);
    }

    function test_sendTokens_revertsWhenOtherSideNotConfigured() public {
        PaymentsGateway fresh = _deployGateway(address(bridge), address(factory));
        vm.prank(USER);
        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        fresh.sendTokens(address(originToken), RECIPIENT, 1);
    }

    function test_sendNativeTokens_revertsWhenOtherSideNotConfigured() public {
        PaymentsGateway fresh = _deployGateway(address(bridge), address(factory));
        vm.deal(USER, 1 ether);
        vm.prank(USER);
        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        fresh.sendNativeTokens{value: 1}(RECIPIENT, 1);
    }

    function test_receiveNativeTokens_viaBridge_forwardsEth() public {
        uint256 amount = 3;
        vm.deal(address(bridge), amount);
        uint256 recipientBefore = RECIPIENT.balance;
        bytes memory message = abi.encodeCall(PaymentsGateway.receiveNativeTokens, (USER, RECIPIENT, amount));

        bridge.receiveMessage(
            OTHER_SIDE_GATEWAY, address(gateway), amount, block.chainid + 1, 10, bridge.receivedNonce(), message
        );

        assertEq(RECIPIENT.balance, recipientBefore + amount, "recipient should receive bridged native amount");
    }

    function test_receiveNativeTokens_withWrongValue_marksMessageFailed() public {
        uint256 nonce = bridge.receivedNonce();
        uint256 sourceChainId = block.chainid + 1;
        uint256 sourceBlock = 11;
        bytes memory message = abi.encodeCall(PaymentsGateway.receiveNativeTokens, (USER, RECIPIENT, 2));
        bytes32 messageHash =
            keccak256(abi.encode(OTHER_SIDE_GATEWAY, address(gateway), 1, sourceChainId, sourceBlock, nonce, message));
        vm.deal(address(bridge), 1);

        bridge.receiveMessage(OTHER_SIDE_GATEWAY, address(gateway), 1, sourceChainId, sourceBlock, nonce, message);

        assertEq(
            uint256(bridge.receivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "message should fail"
        );
    }

    function test_receivePeggedTokens_wrongGatewaySender_marksFailed() public {
        uint256 nonce = bridge.receivedNonce();
        uint256 sourceChainId = block.chainid + 1;
        uint256 sourceBlock = 12;
        address predictedPegged = gateway.computePeggedTokenAddress(address(originToken));
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock", uint8(18));
        bytes memory message = abi.encodeCall(
            PaymentsGateway.receivePeggedTokens,
            (address(originToken), predictedPegged, USER, RECIPIENT, 1, tokenMetadata)
        );
        bytes32 messageHash =
            keccak256(abi.encode(address(0x9999), address(gateway), 0, sourceChainId, sourceBlock, nonce, message));

        bridge.receiveMessage(address(0x9999), address(gateway), 0, sourceChainId, sourceBlock, nonce, message);

        assertEq(
            uint256(bridge.receivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "message should fail"
        );
    }

    function test_receiveOriginTokens_wrongGatewaySender_marksFailed() public {
        uint256 nonce = bridge.receivedNonce();
        uint256 sourceChainId = block.chainid + 1;
        uint256 sourceBlock = 13;
        bytes memory message =
            abi.encodeCall(PaymentsGateway.receiveOriginTokens, (address(originToken), USER, RECIPIENT, 1));
        bytes32 messageHash =
            _bridgeMessageHash(WRONG_SIDE_GATEWAY, address(gateway), 0, sourceChainId, sourceBlock, nonce, message);

        bridge.receiveMessage(WRONG_SIDE_GATEWAY, address(gateway), 0, sourceChainId, sourceBlock, nonce, message);

        assertEq(
            uint256(bridge.receivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "message should fail"
        );
    }

    function test_receiveNativeTokens_wrongGatewaySender_marksFailed() public {
        uint256 nonce = bridge.receivedNonce();
        uint256 sourceChainId = block.chainid + 1;
        uint256 sourceBlock = 14;
        bytes memory message = abi.encodeCall(PaymentsGateway.receiveNativeTokens, (USER, RECIPIENT, 1));
        bytes32 messageHash =
            _bridgeMessageHash(WRONG_SIDE_GATEWAY, address(gateway), 1, sourceChainId, sourceBlock, nonce, message);
        vm.deal(address(bridge), 1);

        bridge.receiveMessage(WRONG_SIDE_GATEWAY, address(gateway), 1, sourceChainId, sourceBlock, nonce, message);

        assertEq(
            uint256(bridge.receivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "message should fail"
        );
    }

    function test_receivePeggedTokens_existingTokenPath_mintsAgain() public {
        address predictedPegged = gateway.computePeggedTokenAddress(address(originToken));
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock", uint8(18));
        bytes memory message1 = abi.encodeCall(
            PaymentsGateway.receivePeggedTokens,
            (address(originToken), predictedPegged, USER, RECIPIENT, 4, tokenMetadata)
        );
        bridge.receiveMessage(
            OTHER_SIDE_GATEWAY, address(gateway), 0, block.chainid + 1, 21, bridge.receivedNonce(), message1
        );

        bytes memory message2 = abi.encodeCall(
            PaymentsGateway.receivePeggedTokens,
            (address(originToken), predictedPegged, USER, RECIPIENT, 6, tokenMetadata)
        );
        bridge.receiveMessage(
            OTHER_SIDE_GATEWAY, address(gateway), 0, block.chainid + 1, 22, bridge.receivedNonce(), message2
        );

        assertEq(
            ERC20PeggedToken(predictedPegged).balanceOf(RECIPIENT),
            10,
            "second receive should mint on existing pegged token"
        );
    }

    function test_sendTokens_peggedTokenPath_burnsTokens() public {
        address predictedPegged = gateway.computePeggedTokenAddress(address(originToken));
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock", uint8(18));
        bytes memory message = abi.encodeCall(
            PaymentsGateway.receivePeggedTokens, (address(originToken), predictedPegged, USER, USER, 10, tokenMetadata)
        );
        bridge.receiveMessage(
            OTHER_SIDE_GATEWAY, address(gateway), 0, block.chainid + 1, 31, bridge.receivedNonce(), message
        );

        ERC20PeggedToken pegged = ERC20PeggedToken(predictedPegged);
        vm.prank(USER);
        pegged.approve(address(gateway), 4);

        uint256 supplyBefore = pegged.totalSupply();
        vm.prank(USER);
        gateway.sendTokens(predictedPegged, RECIPIENT, 4);
        uint256 supplyAfter = pegged.totalSupply();

        assertEq(supplyAfter, supplyBefore - 4, "pegged token send should burn");
    }

    function test_sendTokens_peggedTokenPath_revertsOnMappingMismatch() public {
        address predictedPegged = gateway.computePeggedTokenAddress(address(originToken));
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock", uint8(18));
        bytes memory message = abi.encodeCall(
            PaymentsGateway.receivePeggedTokens, (address(originToken), predictedPegged, USER, USER, 10, tokenMetadata)
        );
        bridge.receiveMessage(
            OTHER_SIDE_GATEWAY, address(gateway), 0, block.chainid + 1, 41, bridge.receivedNonce(), message
        );

        ERC20PeggedToken pegged = ERC20PeggedToken(predictedPegged);
        gateway.updateTokenMapping(address(0xDEAD), predictedPegged);

        vm.prank(USER);
        pegged.approve(address(gateway), 5);
        vm.prank(USER);
        vm.expectRevert(bytes4(keccak256("TokenMappingCheckFailed()")));
        gateway.sendTokens(predictedPegged, RECIPIENT, 5);
    }

    function test_receivePeggedTokens_revertsOnOriginZero_marksFailed() public {
        uint256 nonce = bridge.receivedNonce();
        uint256 sourceChainId = block.chainid + 1;
        uint256 sourceBlock = 15;
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock", uint8(18));
        bytes memory message = abi.encodeCall(
            PaymentsGateway.receivePeggedTokens, (address(0), address(0xABCDEF), USER, RECIPIENT, 1, tokenMetadata)
        );
        bytes32 messageHash =
            _bridgeMessageHash(OTHER_SIDE_GATEWAY, address(gateway), 0, sourceChainId, sourceBlock, nonce, message);

        bridge.receiveMessage(OTHER_SIDE_GATEWAY, address(gateway), 0, sourceChainId, sourceBlock, nonce, message);

        assertEq(
            uint256(bridge.receivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "message should fail"
        );
    }

    function test_receivePeggedTokens_revertsOnInvalidRecipient_marksFailed() public {
        uint256 nonce = bridge.receivedNonce();
        uint256 sourceChainId = block.chainid + 1;
        uint256 sourceBlock = 16;
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock", uint8(18));
        bytes memory message = abi.encodeCall(
            PaymentsGateway.receivePeggedTokens,
            (address(originToken), address(0xABCD), USER, address(0), 1, tokenMetadata)
        );
        bytes32 messageHash =
            _bridgeMessageHash(OTHER_SIDE_GATEWAY, address(gateway), 0, sourceChainId, sourceBlock, nonce, message);

        bridge.receiveMessage(OTHER_SIDE_GATEWAY, address(gateway), 0, sourceChainId, sourceBlock, nonce, message);

        assertEq(
            uint256(bridge.receivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "message should fail"
        );
    }

    function test_receiveOriginTokens_revertsOnInvalidRecipient_marksFailed() public {
        uint256 nonce = bridge.receivedNonce();
        uint256 sourceChainId = block.chainid + 1;
        uint256 sourceBlock = 17;
        bytes memory message =
            abi.encodeCall(PaymentsGateway.receiveOriginTokens, (address(originToken), USER, address(0), 1));
        bytes32 messageHash =
            _bridgeMessageHash(OTHER_SIDE_GATEWAY, address(gateway), 0, sourceChainId, sourceBlock, nonce, message);

        bridge.receiveMessage(OTHER_SIDE_GATEWAY, address(gateway), 0, sourceChainId, sourceBlock, nonce, message);

        assertEq(
            uint256(bridge.receivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "message should fail"
        );
    }

    function test_receiveNativeTokens_revertsOnInvalidRecipient_marksFailed() public {
        uint256 nonce = bridge.receivedNonce();
        uint256 sourceChainId = block.chainid + 1;
        uint256 sourceBlock = 18;
        bytes memory message = abi.encodeCall(PaymentsGateway.receiveNativeTokens, (USER, address(0), 1));
        bytes32 messageHash =
            _bridgeMessageHash(OTHER_SIDE_GATEWAY, address(gateway), 1, sourceChainId, sourceBlock, nonce, message);
        vm.deal(address(bridge), 1);

        bridge.receiveMessage(OTHER_SIDE_GATEWAY, address(gateway), 1, sourceChainId, sourceBlock, nonce, message);

        assertEq(
            uint256(bridge.receivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "message should fail"
        );
    }

    function test_receiveNativeTokens_transferFail_marksFailed() public {
        RejectEther rejector = new RejectEther();
        uint256 nonce = bridge.receivedNonce();
        uint256 sourceChainId = block.chainid + 1;
        uint256 sourceBlock = 19;
        bytes memory message = abi.encodeCall(PaymentsGateway.receiveNativeTokens, (USER, address(rejector), 1));
        bytes32 messageHash =
            _bridgeMessageHash(OTHER_SIDE_GATEWAY, address(gateway), 1, sourceChainId, sourceBlock, nonce, message);
        vm.deal(address(bridge), 1);

        bridge.receiveMessage(OTHER_SIDE_GATEWAY, address(gateway), 1, sourceChainId, sourceBlock, nonce, message);

        assertEq(
            uint256(bridge.receivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "message should fail"
        );
    }

    function test_adminSetters_andRescueNative() public {
        ERC20TokenFactory newFactory = _deployFactory(address(peggedImplementation));
        gateway.setTokenFactory(address(newFactory));
        assertEq(gateway.tokenFactory(), address(newFactory), "tokenFactory should update");

        gateway.setOtherSideGateway(address(0xAAAA));
        assertEq(gateway.otherSide(), address(0xAAAA), "otherSide should update");

        gateway.setOtherSideTokenImplementation(address(0xBBBB));
        assertEq(gateway.otherSideTokenImplementation(), address(0xBBBB), "otherSide implementation should update");

        gateway.setOtherSide(address(0xCCCC), address(0xDDDD), address(0xEEEE), address(0xBBBB));
        assertEq(gateway.otherSide(), address(0xCCCC), "otherSide set should update");
        assertEq(gateway.otherSideFactory(), address(0xEEEE), "otherSideFactory set should update");

        gateway.updateTokenMapping(address(originToken), address(0xFEEE));
        assertEq(gateway.tokenMapping(address(0xFEEE)), address(originToken), "mapping should update");

        vm.deal(address(gateway), 2);
        uint256 beforeRecipient = RECIPIENT.balance;
        gateway.rescueNative(payable(RECIPIENT), 2);
        assertEq(RECIPIENT.balance, beforeRecipient + 2, "rescue should transfer eth");
    }

    function test_adminSetters_revertOnZeroAddress() public {
        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        gateway.setTokenFactory(address(0));

        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        gateway.setOtherSideGateway(address(0));

        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        gateway.setOtherSideTokenImplementation(address(0));

        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        gateway.setOtherSide(address(0), address(1), address(2), address(3));

        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        gateway.setOtherSide(address(1), address(0), address(2), address(3));

        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        gateway.setOtherSide(address(1), address(2), address(0), address(3));

        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        gateway.setOtherSide(address(1), address(2), address(3), address(0));
    }

    function test_receiveFunctions_revertWhenCallerNotBridge() public {
        vm.expectRevert(bytes4(keccak256("OnlyBridgeSender()")));
        gateway.receiveOriginTokens(address(originToken), USER, RECIPIENT, 1);

        vm.expectRevert(bytes4(keccak256("OnlyBridgeSender()")));
        gateway.receiveNativeTokens(USER, RECIPIENT, 1);

        vm.expectRevert(bytes4(keccak256("OnlyBridgeSender()")));
        gateway.receivePeggedTokens(
            address(originToken), address(0xABCD), USER, RECIPIENT, 1, abi.encode("MOCK", "Mock", uint8(18))
        );
    }

    function test_acceptTokenFactory_revertsForNonOwner() public {
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", USER));
        gateway.acceptTokenFactory();
    }

    function test_rescueNative_revertsOnRecipientReject() public {
        RejectEther rejector = new RejectEther();
        vm.deal(address(gateway), 1);
        vm.expectRevert(bytes4(keccak256("NativeTransferFailed()")));
        gateway.rescueNative(payable(address(rejector)), 1);
    }

    function test_rescueNative_revertsOnZeroRecipient() public {
        vm.expectRevert(bytes4(keccak256("InvalidRecipient()")));
        gateway.rescueNative(payable(address(0)), 1);
    }

    function test_updateTokenMapping_revertsOnZeroAddresses() public {
        vm.expectRevert(bytes4(keccak256("TokenAddressZero()")));
        gateway.updateTokenMapping(address(0), address(0xABCD));

        vm.expectRevert(bytes4(keccak256("TokenAddressZero()")));
        gateway.updateTokenMapping(address(originToken), address(0));
    }

    function test_adminFunctions_revertForNonOwner() public {
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", USER));
        gateway.setTokenFactory(address(factory));

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", USER));
        gateway.setOtherSideGateway(OTHER_SIDE_GATEWAY);

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", USER));
        gateway.setOtherSideTokenImplementation(address(peggedImplementation));

        address beaconAddr = factory.beacon();
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", USER));
        gateway.setOtherSide(OTHER_SIDE_GATEWAY, address(peggedImplementation), address(factory), beaconAddr);
    }

    function test_receivePeggedTokens_wrongPeggedTokenPrediction_marksFailed() public {
        uint256 nonce = bridge.receivedNonce();
        uint256 sourceChainId = block.chainid + 1;
        uint256 sourceBlock = 20;
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock", uint8(18));
        bytes memory message = abi.encodeCall(
            PaymentsGateway.receivePeggedTokens,
            (address(originToken), address(0xDEADBEEF), USER, RECIPIENT, 1, tokenMetadata)
        );
        bytes32 messageHash =
            _bridgeMessageHash(OTHER_SIDE_GATEWAY, address(gateway), 0, sourceChainId, sourceBlock, nonce, message);

        bridge.receiveMessage(OTHER_SIDE_GATEWAY, address(gateway), 0, sourceChainId, sourceBlock, nonce, message);
        assertEq(
            uint256(bridge.receivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "message should fail"
        );
    }

    function test_receivePeggedTokens_existingTokenWrongMapping_marksFailed() public {
        address predictedPegged = gateway.computePeggedTokenAddress(address(originToken));
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock", uint8(18));
        bytes memory setupMessage = abi.encodeCall(
            PaymentsGateway.receivePeggedTokens,
            (address(originToken), predictedPegged, USER, RECIPIENT, 1, tokenMetadata)
        );
        bridge.receiveMessage(
            OTHER_SIDE_GATEWAY, address(gateway), 0, block.chainid + 1, 51, bridge.receivedNonce(), setupMessage
        );

        gateway.updateTokenMapping(address(0xBEEF), predictedPegged);

        uint256 nonce = bridge.receivedNonce();
        uint256 sourceChainId = block.chainid + 1;
        uint256 sourceBlock = 52;
        bytes memory badMessage = abi.encodeCall(
            PaymentsGateway.receivePeggedTokens,
            (address(originToken), predictedPegged, USER, RECIPIENT, 1, tokenMetadata)
        );
        bytes32 messageHash =
            _bridgeMessageHash(OTHER_SIDE_GATEWAY, address(gateway), 0, sourceChainId, sourceBlock, nonce, badMessage);

        bridge.receiveMessage(OTHER_SIDE_GATEWAY, address(gateway), 0, sourceChainId, sourceBlock, nonce, badMessage);
        assertEq(
            uint256(bridge.receivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "message should fail"
        );
    }

    function _deployBridge() internal returns (FluentBridge deployed) {
        FluentBridge impl = new FluentBridge();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                FluentBridge.initialize, (address(this), address(this), address(0), 0, address(0x1234), address(0x5678))
            )
        );
        deployed = FluentBridge(payable(address(proxy)));
    }

    function _deployFactory(address implementation) internal returns (ERC20TokenFactory deployed) {
        ERC20TokenFactory impl = new ERC20TokenFactory();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(ERC20TokenFactory.initialize, (address(this), implementation))
        );
        deployed = ERC20TokenFactory(address(proxy));
    }

    function _deployGateway(address bridgeAddress, address factoryAddress)
        internal
        returns (PaymentsGateway deployed)
    {
        PaymentsGateway impl = new PaymentsGateway();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(PaymentsGateway.initialize, (address(this), bridgeAddress, factoryAddress))
        );
        deployed = PaymentsGateway(payable(address(proxy)));
    }

    function assertEq(address left, address right, string memory message) internal pure {
        require(left == right, message);
    }

    function assertEq(uint256 left, uint256 right, string memory message) internal pure {
        require(left == right, message);
    }

    function _bridgeMessageHash(
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 nonce,
        bytes memory message
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(from, to, value, chainId, blockNumber, nonce, message));
    }
}
