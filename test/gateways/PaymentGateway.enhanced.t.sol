// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FluentBridge} from "../../contracts/FluentBridge.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";
import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";
import {PaymentGateway} from "../../contracts/gateways/PaymentGateway.sol";
import {IGateway} from "../../contracts/interfaces/IGateway.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {MockERC20Token} from "../../contracts/mocks/MockERC20.sol";
import {Vm} from "../Rollup/Base.t.sol";

contract RevertingReceiver {
    receive() external payable {
        revert("Reverting receiver");
    }
}

contract PaymentGatewayEnhancedTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant USER = address(0x1111);
    address internal constant RECIPIENT = address(0x2222);
    address internal constant OTHER_GATEWAY = address(0x3333);
    address internal constant WRONG_GATEWAY = address(0x4444);
    address internal constant ATTACKER = address(0xBAD);

    FluentBridge internal bridge;
    ERC20TokenFactory internal factory;
    PaymentGateway internal gateway;
    ERC20PeggedToken internal peggedImplementation;

    function setUp() public {
        bridge = _deployBridge();
        peggedImplementation = new ERC20PeggedToken();
        factory = _deployFactory(address(peggedImplementation));
        gateway = _deployGateway(address(bridge), address(factory));

        factory.setPaymentGateway(address(gateway));
        gateway.setOtherSide(OTHER_GATEWAY, address(peggedImplementation), address(factory), factory.beacon());
    }

    function _deployBridge() internal returns (FluentBridge) {
        FluentBridge impl = new FluentBridge();
        FluentBridge.InitConfiguration memory config = FluentBridge.InitConfiguration({
            initialOwner: address(this),
            bridgeAuthority: address(this),
            rollup: address(0),
            receiveMessageDeadline: 0,
            otherBridge: address(0x9999),
            l1BlockOracle: address(0)
        });
        return FluentBridge(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(FluentBridge.initialize, (abi.encode(config)))))));
    }

    function _deployFactory(address implementation) internal returns (ERC20TokenFactory) {
        ERC20TokenFactory impl = new ERC20TokenFactory();
        bytes memory initData = abi.encodeCall(ERC20TokenFactory.initialize, (address(this), implementation));
        return ERC20TokenFactory(address(new ERC1967Proxy(address(impl), initData)));
    }

    function _deployGateway(address _bridge, address _factory) internal returns (PaymentGateway) {
        PaymentGateway impl = new PaymentGateway();
        return PaymentGateway(payable(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(PaymentGateway.initialize, (address(this), _bridge, _factory))
        ))));
    }

    // ========== Initialization Tests ==========

    function testInitializeSetsCorrectValues() public view {
        require(gateway.owner() == address(this), "owner mismatch");
        require(gateway.bridgeContract() == address(bridge), "bridge mismatch");
        require(gateway.tokenFactory() == address(factory), "factory mismatch");
        require(gateway.gasLimit() == gateway.DEFAULT_GAS_LIMIT(), "gas limit mismatch");
    }

    function testInitializeRevertsOnZeroAddress() public {
        PaymentGateway impl = new PaymentGateway();

        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(PaymentGateway.initialize, (address(0), address(bridge), address(factory)))
        );

        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(PaymentGateway.initialize, (address(this), address(0), address(factory)))
        );

        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(PaymentGateway.initialize, (address(this), address(bridge), address(0)))
        );
    }

    // ========== Send Native Tokens Tests ==========

    function testSendNativeTokensRequiresMatchingValue() public {
        uint256 amount = 1 ether;
        vm.deal(USER, amount);

        vm.prank(USER);
        vm.expectRevert(bytes4(keccak256("InvalidNativeAmount()")));
        gateway.sendNativeTokens{value: 0.5 ether}(RECIPIENT, amount);
    }

    function testSendNativeTokensRevertsOnZeroRecipient() public {
        vm.deal(USER, 1 ether);

        vm.prank(USER);
        vm.expectRevert(bytes4(keccak256("InvalidRecipient()")));
        gateway.sendNativeTokens{value: 1 ether}(address(0), 1 ether);
    }

    function testSendNativeTokensRevertsWhenOtherSideNotSet() public {
        PaymentGateway freshGateway = _deployGateway(address(bridge), address(factory));
        vm.deal(USER, 1 ether);

        vm.prank(USER);
        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        freshGateway.sendNativeTokens{value: 1 ether}(RECIPIENT, 1 ether);
    }

    function testSendNativeTokensCallsBridge() public {
        uint256 amount = 1 ether;
        vm.deal(USER, amount);

        uint256 nonceBefore = bridge.nonce();
        vm.prank(USER);
        gateway.sendNativeTokens{value: amount}(RECIPIENT, amount);

        require(bridge.nonce() == nonceBefore + 1, "bridge nonce should increment");
    }

    // ========== Send ERC20 Tokens Tests ==========

    function testSendTokensOriginTokenLocksInGateway() public {
        MockERC20Token token = new MockERC20Token("Test", "TST", 1000 ether, USER);

        uint256 amount = 10 ether;
        vm.prank(USER);
        token.approve(address(gateway), amount);

        vm.prank(USER);
        gateway.sendTokens(address(token), RECIPIENT, amount);

        require(token.balanceOf(address(gateway)) == amount, "gateway should hold tokens");
    }

    function testSendTokensRevertsOnZeroRecipient() public {
        MockERC20Token token = new MockERC20Token("Test", "TST", 1000 ether, USER);

        vm.prank(USER);
        token.approve(address(gateway), 10 ether);

        vm.prank(USER);
        vm.expectRevert(bytes4(keccak256("InvalidRecipient()")));
        gateway.sendTokens(address(token), address(0), 10 ether);
    }

    function testSendTokensRevertsWhenOtherSideNotSet() public {
        PaymentGateway freshGateway = _deployGateway(address(bridge), address(factory));
        MockERC20Token token = new MockERC20Token("Test", "TST", 1000 ether, USER);

        vm.prank(USER);
        token.approve(address(freshGateway), 10 ether);

        vm.prank(USER);
        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        freshGateway.sendTokens(address(token), RECIPIENT, 10 ether);
    }

    // ========== Receive Pegged Tokens Tests ==========

    function testReceivePeggedTokensDeploysNewToken() public {
        address originToken = address(0x5678);
        uint256 amount = 5 ether;
        address predictedPegged = gateway.computePeggedTokenAddress(originToken);

        bytes memory tokenMetadata = abi.encode("TST", "Test Token", uint8(18));
        bytes memory message = abi.encodeCall(
            PaymentGateway.receivePeggedTokens,
            (originToken, predictedPegged, USER, RECIPIENT, amount, tokenMetadata)
        );

        bridge.receiveMessage(OTHER_GATEWAY, address(gateway), 0, block.chainid + 1, 1, bridge.receivedNonce(), message);

        require(predictedPegged.code.length > 0, "token should be deployed");
        require(gateway.tokenMapping(predictedPegged) == originToken, "mapping should be set");
    }

    function testReceivePeggedTokensMintsToRecipient() public {
        address originToken = address(0x5678);
        uint256 amount = 5 ether;
        address predictedPegged = gateway.computePeggedTokenAddress(originToken);

        bytes memory tokenMetadata = abi.encode("TST", "Test Token", uint8(18));
        bytes memory message = abi.encodeCall(
            PaymentGateway.receivePeggedTokens,
            (originToken, predictedPegged, USER, RECIPIENT, amount, tokenMetadata)
        );

        bridge.receiveMessage(OTHER_GATEWAY, address(gateway), 0, block.chainid + 1, 1, bridge.receivedNonce(), message);

        require(ERC20PeggedToken(predictedPegged).balanceOf(RECIPIENT) == amount, "recipient should receive tokens");
    }

    function testReceivePeggedTokensRevertsOnWrongGateway() public {
        address originToken = address(0x5678);
        address predictedPegged = gateway.computePeggedTokenAddress(originToken);

        bytes memory tokenMetadata = abi.encode("TST", "Test Token", uint8(18));
        bytes memory message = abi.encodeCall(
            PaymentGateway.receivePeggedTokens,
            (originToken, predictedPegged, USER, RECIPIENT, 5 ether, tokenMetadata)
        );

        vm.expectRevert(bytes4(keccak256("MessageFromWrongGateway()")));
        bridge.receiveMessage(WRONG_GATEWAY, address(gateway), 0, block.chainid + 1, 1, bridge.receivedNonce(), message);
    }

    function testReceivePeggedTokensRevertsOnNonZeroValue() public {
        address originToken = address(0x5678);
        address predictedPegged = gateway.computePeggedTokenAddress(originToken);

        bytes memory tokenMetadata = abi.encode("TST", "Test Token", uint8(18));
        bytes memory message = abi.encodeCall(
            PaymentGateway.receivePeggedTokens,
            (originToken, predictedPegged, USER, RECIPIENT, 5 ether, tokenMetadata)
        );

        vm.expectRevert(bytes4(keccak256("MessageValueMustBeZero()")));
        bridge.receiveMessage{value: 1 ether}(OTHER_GATEWAY, address(gateway), 1 ether, block.chainid + 1, 1, bridge.receivedNonce(), message);
    }

    function testReceivePeggedTokensRevertsOnZeroOriginToken() public {
        address predictedPegged = gateway.computePeggedTokenAddress(address(0x5678));

        bytes memory tokenMetadata = abi.encode("TST", "Test Token", uint8(18));
        bytes memory message = abi.encodeCall(
            PaymentGateway.receivePeggedTokens,
            (address(0), predictedPegged, USER, RECIPIENT, 5 ether, tokenMetadata)
        );

        vm.expectRevert(bytes4(keccak256("OriginTokenZero()")));
        bridge.receiveMessage(OTHER_GATEWAY, address(gateway), 0, block.chainid + 1, 1, bridge.receivedNonce(), message);
    }

    function testReceivePeggedTokensRevertsOnTokenMappingMismatch() public {
        address originToken = address(0x5678);
        address predictedPegged = gateway.computePeggedTokenAddress(originToken);

        // First deployment
        bytes memory tokenMetadata = abi.encode("TST", "Test Token", uint8(18));
        bytes memory message = abi.encodeCall(
            PaymentGateway.receivePeggedTokens,
            (originToken, predictedPegged, USER, RECIPIENT, 5 ether, tokenMetadata)
        );
        bridge.receiveMessage(OTHER_GATEWAY, address(gateway), 0, block.chainid + 1, 1, bridge.receivedNonce(), message);

        // Try to receive with wrong origin
        bytes memory message2 = abi.encodeCall(
            PaymentGateway.receivePeggedTokens,
            (address(0x9999), predictedPegged, USER, RECIPIENT, 5 ether, tokenMetadata)
        );

        vm.expectRevert(bytes4(keccak256("TokenMappingCheckFailed()")));
        bridge.receiveMessage(OTHER_GATEWAY, address(gateway), 0, block.chainid + 1, 2, bridge.receivedNonce(), message2);
    }

    // ========== Receive Origin Tokens Tests ==========

    function testReceiveOriginTokensTransfersFromGateway() public {
        MockERC20Token token = new MockERC20Token("Test", "TST", 1000 ether, address(gateway));

        uint256 amount = 10 ether;
        bytes memory message = abi.encodeCall(
            PaymentGateway.receiveOriginTokens,
            (address(token), USER, RECIPIENT, amount)
        );

        uint256 recipientBefore = token.balanceOf(RECIPIENT);
        bridge.receiveMessage(OTHER_GATEWAY, address(gateway), 0, block.chainid + 1, 1, bridge.receivedNonce(), message);

        require(token.balanceOf(RECIPIENT) == recipientBefore + amount, "recipient should receive tokens");
    }

    function testReceiveOriginTokensRevertsOnWrongGateway() public {
        MockERC20Token token = new MockERC20Token("Test", "TST", 1000 ether, address(gateway));

        bytes memory message = abi.encodeCall(
            PaymentGateway.receiveOriginTokens,
            (address(token), USER, RECIPIENT, 10 ether)
        );

        vm.expectRevert(bytes4(keccak256("MessageFromWrongGateway()")));
        bridge.receiveMessage(WRONG_GATEWAY, address(gateway), 0, block.chainid + 1, 1, bridge.receivedNonce(), message);
    }

    function testReceiveOriginTokensRevertsOnNonZeroValue() public {
        MockERC20Token token = new MockERC20Token("Test", "TST", 1000 ether, address(gateway));

        bytes memory message = abi.encodeCall(
            PaymentGateway.receiveOriginTokens,
            (address(token), USER, RECIPIENT, 10 ether)
        );

        vm.expectRevert(bytes4(keccak256("MessageValueMustBeZero()")));
        bridge.receiveMessage{value: 1 ether}(OTHER_GATEWAY, address(gateway), 1 ether, block.chainid + 1, 1, bridge.receivedNonce(), message);
    }

    // ========== Receive Native Tokens Tests ==========

    function testReceiveNativeTokensTransfersToRecipient() public {
        uint256 amount = 1 ether;
        vm.deal(address(bridge), amount);

        bytes memory message = abi.encodeCall(
            PaymentGateway.receiveNativeTokens,
            (USER, RECIPIENT, amount)
        );

        uint256 recipientBefore = RECIPIENT.balance;
        bridge.receiveMessage{value: amount}(OTHER_GATEWAY, address(gateway), amount, block.chainid + 1, 1, bridge.receivedNonce(), message);

        require(RECIPIENT.balance == recipientBefore + amount, "recipient should receive native tokens");
    }

    function testReceiveNativeTokensRevertsOnValueMismatch() public {
        uint256 amount = 1 ether;
        vm.deal(address(bridge), amount);

        bytes memory message = abi.encodeCall(
            PaymentGateway.receiveNativeTokens,
            (USER, RECIPIENT, amount)
        );

        vm.expectRevert(bytes4(keccak256("InvalidNativeAmount()")));
        bridge.receiveMessage{value: 0.5 ether}(OTHER_GATEWAY, address(gateway), 0.5 ether, block.chainid + 1, 1, bridge.receivedNonce(), message);
    }

    function testReceiveNativeTokensRevertsOnRevertingRecipient() public {
        RevertingReceiver receiver = new RevertingReceiver();
        uint256 amount = 1 ether;
        vm.deal(address(bridge), amount);

        bytes memory message = abi.encodeCall(
            PaymentGateway.receiveNativeTokens,
            (USER, address(receiver), amount)
        );

        vm.expectRevert(bytes4(keccak256("NativeTransferFailed()")));
        bridge.receiveMessage{value: amount}(OTHER_GATEWAY, address(gateway), amount, block.chainid + 1, 1, bridge.receivedNonce(), message);
    }

    // ========== Admin Functions Tests ==========

    function testSetOtherSideUpdatesAllValues() public {
        address newOtherSide = address(0xAAAA);
        address newImpl = address(0xBBBB);
        address newFactory = address(0xCCCC);
        address newBeacon = address(0xDDDD);

        gateway.setOtherSide(newOtherSide, newImpl, newFactory, newBeacon);

        require(gateway.otherSide() == newOtherSide, "otherSide mismatch");
        require(gateway.otherSideTokenImplementation() == newImpl, "impl mismatch");
        require(gateway.otherSideFactory() == newFactory, "factory mismatch");
        require(gateway.otherSideBeacon() == newBeacon, "beacon mismatch");
    }

    function testSetGasLimitUpdates() public {
        uint256 newLimit = 100000;
        gateway.setGasLimit(newLimit);
        require(gateway.gasLimit() == newLimit, "gas limit should update");
    }

    function testSetGasLimitRevertsOnZero() public {
        vm.expectRevert(bytes4(keccak256("InvalidGasLimit()")));
        gateway.setGasLimit(0);
    }

    function testUpdateTokenMappingUpdates() public {
        address origin = address(0x1111);
        address pegged = address(0x2222);

        gateway.updateTokenMapping(origin, pegged);

        require(gateway.tokenMapping(pegged) == origin, "mapping should update");
    }

    function testUpdateTokenMappingRevertsOnZeroAddresses() public {
        vm.expectRevert(bytes4(keccak256("TokenAddressZero()")));
        gateway.updateTokenMapping(address(0), address(0x2222));

        vm.expectRevert(bytes4(keccak256("TokenAddressZero()")));
        gateway.updateTokenMapping(address(0x1111), address(0));
    }

    function testOnlyOwnerCanCallAdminFunctions() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER));
        gateway.setOtherSide(address(0x1), address(0x2), address(0x3), address(0x4));

        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER));
        gateway.setGasLimit(100000);

        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER));
        gateway.updateTokenMapping(address(0x1), address(0x2));
    }

    // ========== Rescue Native Tests ==========

    function testRescueNativeTransfersEth() public {
        uint256 amount = 1 ether;
        vm.deal(address(gateway), amount);

        uint256 recipientBefore = RECIPIENT.balance;
        gateway.rescueNative(payable(RECIPIENT), amount);

        require(RECIPIENT.balance == recipientBefore + amount, "recipient should receive eth");
    }

    function testRescueNativeRevertsOnZeroRecipient() public {
        vm.expectRevert(bytes4(keccak256("InvalidRecipient()")));
        gateway.rescueNative(payable(address(0)), 1 ether);
    }

    function testRescueNativeOnlyOwner() public {
        vm.deal(address(gateway), 1 ether);

        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER));
        gateway.rescueNative(payable(RECIPIENT), 1 ether);
    }

    // ========== Receive Function Tests ==========

    function testReceiveFunctionAcceptsEth() public {
        vm.deal(USER, 1 ether);

        vm.prank(USER);
        (bool success,) = address(gateway).call{value: 1 ether}("");

        require(success, "receive should accept eth");
        require(address(gateway).balance == 1 ether, "gateway balance should increase");
    }

    // ========== Compute Address Tests ==========

    function testComputePeggedTokenAddressConsistency() public view {
        address token = address(0x1234);
        address computed1 = gateway.computePeggedTokenAddress(token);
        address computed2 = gateway.computePeggedTokenAddress(token);

        require(computed1 == computed2, "computed addresses should be consistent");
    }

    function testComputeOtherSidePeggedTokenAddressConsistency() public view {
        address token = address(0x1234);
        address computed1 = gateway.computeOtherSidePeggedTokenAddress(token);
        address computed2 = gateway.computeOtherSidePeggedTokenAddress(token);

        require(computed1 == computed2, "other side addresses should be consistent");
    }
}