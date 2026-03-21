// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {NativeGateway} from "../../contracts/gateways/NativeGateway.sol";
import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {IGatewayErrors, IGatewayEvents} from "../../contracts/interfaces/gateways/IGateway.sol";
import {INativeGatewayErrors} from "../../contracts/interfaces/gateways/INativeGateway.sol";
import {GatewayBase} from "./Base.t.sol";
import {RejectEther} from "../Bridge/Base.t.sol";

contract NativeGatewayTest is GatewayBase {
    NativeGateway internal nativeGateway;

    function setUp() public override {
        super.setUp();
        _deployBridge(0);
        _deployNativeGateway();
    }

    function _deployNativeGateway() internal {
        NativeGateway impl = new NativeGateway();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(NativeGateway.initialize, (admin, address(bridge))));
        nativeGateway = NativeGateway(payable(address(proxy)));

        vm.prank(admin);
        nativeGateway.setOtherSideGateway(remoteGateway);
    }

    function test_initialize_setsDefaults() public {
        assertEq(nativeGateway.owner(), admin);
        assertEq(nativeGateway.getBridgeContract(), address(bridge));
        assertEq(nativeGateway.getOtherSideGateway(), remoteGateway);
        assertEq(nativeGateway.getGasLimit(), nativeGateway.DEFAULT_GAS_LIMIT());
    }

    function test_sendNativeTokens_locksNativeInBridge() public {
        uint256 amount = 1 ether;
        vm.deal(user, amount);

        vm.prank(user);
        nativeGateway.sendNativeTokens{value: amount}(recipient, amount);

        assertEq(address(bridge).balance, amount);
    }

    function test_sendNativeTokens_revertsForZeroRecipient() public {
        uint256 amount = 1 ether;
        vm.deal(user, amount);

        vm.prank(user);
        vm.expectRevert(IGatewayErrors.InvalidRecipient.selector);
        nativeGateway.sendNativeTokens{value: amount}(address(0), amount);
    }

    function test_sendNativeTokens_revertsForInvalidAmount() public {
        vm.deal(user, 1 ether);

        vm.prank(user);
        vm.expectRevert(INativeGatewayErrors.InvalidNativeAmount.selector);
        nativeGateway.sendNativeTokens{value: 1 ether}(recipient, 2 ether);
    }

    function test_sendNativeTokens_withoutOtherSideGateway_sendsToZeroAddress() public {
        NativeGateway impl = new NativeGateway();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(NativeGateway.initialize, (admin, address(bridge))));
        NativeGateway localGateway = NativeGateway(payable(address(proxy)));
        uint256 amount = 0.5 ether;
        vm.deal(user, amount);

        vm.prank(user);
        localGateway.sendNativeTokens{value: amount}(recipient, amount);

        // Current behavior: no explicit otherSide check in NativeGateway, so bridge accepts message.
        assertEq(address(bridge).balance, amount);
    }

    function test_receiveNativeTokens_viaBridge_transfersValue() public {
        uint256 amount = 2 ether;
        bytes memory message = abi.encodeCall(NativeGateway.receiveNativeTokens, (user, recipient, amount));
        uint256 beforeRecipient = recipient.balance;
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        bytes32 messageHash = _bridgeMessageHash(remoteGateway, address(nativeGateway), amount, sourceChainId, sourceBlock, nonce, message);
        vm.deal(address(bridge), amount);

        vm.prank(relayer);
        bridge.receiveMessage(remoteGateway, address(nativeGateway), amount, sourceChainId, sourceBlock, nonce, message);

        assertEq(recipient.balance - beforeRecipient, amount);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
    }

    function test_receiveNativeTokens_withRejectingRecipient_marksFailed() public {
        RejectEther rejector = new RejectEther();
        bytes memory message = abi.encodeCall(NativeGateway.receiveNativeTokens, (user, address(rejector), 1 ether));
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        bytes32 messageHash = _bridgeMessageHash(remoteGateway, address(nativeGateway), 1 ether, sourceChainId, sourceBlock, nonce, message);
        vm.deal(address(bridge), 1 ether);

        vm.prank(relayer);
        bridge.receiveMessage(remoteGateway, address(nativeGateway), 1 ether, sourceChainId, sourceBlock, nonce, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_receiveNativeTokens_withZeroRecipient_marksFailed() public {
        bytes memory message = abi.encodeCall(NativeGateway.receiveNativeTokens, (user, address(0), 1 ether));
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        bytes32 messageHash = _bridgeMessageHash(remoteGateway, address(nativeGateway), 1 ether, sourceChainId, sourceBlock, nonce, message);
        vm.deal(address(bridge), 1 ether);

        vm.prank(relayer);
        bridge.receiveMessage(remoteGateway, address(nativeGateway), 1 ether, sourceChainId, sourceBlock, nonce, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_receiveNativeTokens_valuePayloadMismatch_marksFailed() public {
        uint256 bridgeValue = 1 ether;
        uint256 payloadAmount = 2 ether;
        bytes memory message = abi.encodeCall(NativeGateway.receiveNativeTokens, (user, recipient, payloadAmount));
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        bytes32 messageHash = _bridgeMessageHash(remoteGateway, address(nativeGateway), bridgeValue, sourceChainId, sourceBlock, nonce, message);
        vm.deal(address(bridge), bridgeValue);

        vm.prank(relayer);
        bridge.receiveMessage(remoteGateway, address(nativeGateway), bridgeValue, sourceChainId, sourceBlock, nonce, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_receiveNativeTokens_wrongGatewaySender_marksFailed() public {
        bytes memory message = abi.encodeCall(NativeGateway.receiveNativeTokens, (user, recipient, 1 ether));
        address wrongRemoteGateway = makeAddr("wrongRemoteGateway");
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        bytes32 messageHash = _bridgeMessageHash(
            wrongRemoteGateway,
            address(nativeGateway),
            1 ether,
            sourceChainId,
            sourceBlock,
            nonce,
            message
        );
        vm.deal(address(bridge), 1 ether);

        vm.prank(relayer);
        bridge.receiveMessage(wrongRemoteGateway, address(nativeGateway), 1 ether, sourceChainId, sourceBlock, nonce, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_receiveNativeTokens_directCall_revertsOnlyFluentBridge() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(IGatewayErrors.OnlyFluentBridge.selector);
        nativeGateway.receiveNativeTokens{value: 1 ether}(user, recipient, 1 ether);
    }

    function test_setGasLimit_updatesValue() public {
        vm.expectEmit(false, false, false, true, address(nativeGateway));
        emit IGatewayEvents.GasLimitUpdated(nativeGateway.getGasLimit(), 123_456);
        vm.prank(admin);
        nativeGateway.setGasLimit(123_456);
        assertEq(nativeGateway.getGasLimit(), 123_456);
    }

    function test_setGasLimit_revertsForZero() public {
        vm.prank(admin);
        vm.expectRevert(INativeGatewayErrors.InvalidGasLimit.selector);
        nativeGateway.setGasLimit(0);
    }

    function test_setGasLimit_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        nativeGateway.setGasLimit(100_000);
    }

    function test_rescueNative_transfersBalance() public {
        vm.deal(address(nativeGateway), 1 ether);
        uint256 beforeRecipient = recipient.balance;

        vm.prank(admin);
        nativeGateway.rescueNative(payable(recipient), 0.4 ether);

        assertEq(recipient.balance - beforeRecipient, 0.4 ether);
        assertEq(address(nativeGateway).balance, 0.6 ether);
    }

    function test_rescueNative_revertsForZeroRecipient() public {
        vm.prank(admin);
        vm.expectRevert(IGatewayErrors.InvalidRecipient.selector);
        nativeGateway.rescueNative(payable(address(0)), 1);
    }

    function test_setBridgeContract_updatesBridgeAddress() public {
        address newBridge = makeAddr("newBridge");

        vm.expectEmit(false, false, false, true, address(nativeGateway));
        emit IGatewayEvents.BridgeContractUpdated(address(bridge), newBridge);
        vm.prank(admin);
        nativeGateway.setBridgeContract(newBridge);

        assertEq(nativeGateway.getBridgeContract(), newBridge);
    }

    function test_receiveNativeTokens_emitsReceivedTokens() public {
        uint256 amount = 1 ether;
        bytes memory message = abi.encodeCall(NativeGateway.receiveNativeTokens, (user, recipient, amount));
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        vm.deal(address(bridge), amount);

        vm.expectEmit(true, true, false, true, address(nativeGateway));
        emit IGatewayEvents.ReceivedTokens(user, recipient, amount);

        vm.prank(relayer);
        bridge.receiveMessage(remoteGateway, address(nativeGateway), amount, sourceChainId, sourceBlock, nonce, message);
    }

    function test_twoStepOwnership_transferAndAccept() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(admin);
        nativeGateway.transferOwnership(newOwner);
        assertEq(nativeGateway.pendingOwner(), newOwner);

        vm.prank(newOwner);
        nativeGateway.acceptOwnership();
        assertEq(nativeGateway.owner(), newOwner);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, admin));
        nativeGateway.setGasLimit(1);

        vm.prank(newOwner);
        nativeGateway.setGasLimit(33333);
        assertEq(nativeGateway.getGasLimit(), 33333);
    }

    /// @dev Covers `receive()` — native ETH can be sent to the gateway (e.g. accidental transfers / rescues).
    function test_receive_acceptsDirectEth() public {
        vm.deal(user, 2 ether);
        uint256 beforeBal = address(nativeGateway).balance;

        vm.prank(user);
        (bool ok, ) = address(nativeGateway).call{value: 0.25 ether}("");
        assertTrue(ok, "direct ETH transfer to gateway failed");

        assertEq(address(nativeGateway).balance - beforeBal, 0.25 ether);
    }

    function test_bridgePause_blocksSendAndReceive() public {
        vm.prank(admin);
        (bool pauseOk, ) = address(bridge).call(abi.encodeWithSignature("pause()"));
        assertTrue(pauseOk, "bridge pause call failed");

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        nativeGateway.sendNativeTokens{value: 1 ether}(recipient, 1 ether);

        bytes memory message = abi.encodeCall(NativeGateway.receiveNativeTokens, (user, recipient, 1 ether));
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        vm.deal(address(bridge), 1 ether);
        vm.prank(relayer);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        bridge.receiveMessage(remoteGateway, address(nativeGateway), 1 ether, sourceChainId, sourceBlock, nonce, message);
    }
}
