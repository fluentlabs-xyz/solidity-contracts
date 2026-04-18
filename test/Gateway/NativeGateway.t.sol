// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {NativeGateway} from "../../contracts/gateways/NativeGateway.sol";
import {IFluentBridge, IFluentBridgeErrors} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {IGatewayBaseErrors, IGatewayBaseEvents} from "../../contracts/interfaces/gateways/IGatewayBase.sol";
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

        // Bridge gates BOTH `sendMessage` (outbound) and `_receiveMessage` (inbound)
        // against the gateway registry. Register the local native gateway so receives
        // land, and `remoteGateway` so outbound `sendMessage(remoteGateway, ...)` from
        // `sendNativeTokens` passes the symmetric admission check.
        _registerGateway(address(nativeGateway));
        _registerGateway(remoteGateway);

        // Wire the shared FastWithdrawalList so the optimistic-withdrawal policy can be
        // toggled in tests. The native gateway addresses the native asset via
        // `NATIVE_LIMIT_KEY`; tests register that key on the list to exercise rate caps.
        _deployFastWithdrawalList();
        vm.prank(admin);
        nativeGateway.setFastWithdrawalList(address(fastWithdrawalList));
        bytes32 consumerRole = fastWithdrawalList.CONSUMER_ROLE();
        vm.prank(admin);
        fastWithdrawalList.grantRole(consumerRole, address(nativeGateway));
    }

    function test_initialize_setsDefaults() public view {
        assertEq(nativeGateway.owner(), admin);
        assertEq(nativeGateway.getBridgeContract(), address(bridge));
        assertEq(nativeGateway.getOtherSideGateway(), remoteGateway);
    }

    function test_sendNativeTokens_locksNativeInBridge() public {
        uint256 amount = 1 ether;
        vm.deal(user, amount);

        vm.prank(user);
        nativeGateway.sendNativeTokens{value: amount}(recipient);

        assertEq(address(bridge).balance, amount);
    }

    function test_sendNativeTokens_revertsForZeroRecipient() public {
        uint256 amount = 1 ether;
        vm.deal(user, amount);

        vm.prank(user);
        vm.expectRevert(IGatewayBaseErrors.InvalidRecipient.selector);
        nativeGateway.sendNativeTokens{value: amount}(address(0));
    }

    function test_sendNativeTokens_revertsForZeroAmount() public {
        vm.deal(user, 1 ether);

        vm.prank(user);
        vm.expectRevert(INativeGatewayErrors.InvalidNativeAmount.selector);
        nativeGateway.sendNativeTokens{value: 0}(recipient);
    }

    /// @dev Pre-symmetry, an un-configured gateway silently forwarded `sendMessage` to
    ///      `address(0)` and the bridge accepted it — a footgun that trapped user funds.
    ///      The bridge now gates `sendMessage` against the gateway registry symmetric with
    ///      the receive path, and `address(0)` can never be registered, so the bridge
    ///      rejects the call up-front with {GatewayNotWhitelisted}.
    function test_sendNativeTokens_withoutOtherSideGateway_revertsOnUnregisteredDestination() public {
        NativeGateway impl = new NativeGateway();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(NativeGateway.initialize, (admin, address(bridge))));
        NativeGateway localGateway = NativeGateway(payable(address(proxy)));
        uint256 amount = 0.5 ether;
        vm.deal(user, amount);

        vm.prank(user);
        vm.expectRevert(IFluentBridgeErrors.GatewayNotWhitelisted.selector);
        localGateway.sendNativeTokens{value: amount}(recipient);
    }

    /// @dev Relay helper: encode and deliver a `receiveNativeTokens` message through the bridge.
    function _relayReceiveNative(uint256 amount) internal returns (bytes32 messageHash) {
        bytes memory message = abi.encodeCall(NativeGateway.receiveNativeTokens, (user, recipient, amount));
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        messageHash = _bridgeMessageHash(remoteGateway, address(nativeGateway), amount, sourceChainId, sourceBlock, nonce, message);
        vm.deal(address(bridge), address(bridge).balance + amount);
        vm.prank(relayer);
        bridge.receiveMessage(remoteGateway, address(nativeGateway), amount, sourceChainId, sourceBlock, nonce, message);
    }

    /// @dev With whitelist enabled and the originating batch Preconfirmed, the native asset
    ///      key not being on the FastWithdrawalList must reject the receive.
    function test_receiveNativeTokens_marksFailedWhenPreconfirmedAndNativeNotInFastList() public {
        address nativeKey = nativeGateway.NATIVE_LIMIT_KEY();

        vm.prank(admin);
        nativeGateway.setWhitelistEnabled(true);
        _mockBridgePreconfirmed(true);

        bytes32 messageHash = _relayReceiveNative(1 ether);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));

        // Bucket is unregistered, so usage stays at zero.
        (, uint256 hourlyUsed, , uint256 dailyUsed) = fastWithdrawalList.getUsage(nativeKey);
        assertEq(hourlyUsed, 0);
        assertEq(dailyUsed, 0);
    }

    /// @dev With whitelist enabled but batch Finalized (no Preconfirmed signal), the gate is
    ///      a no-op even for the unregistered native key.
    function test_receiveNativeTokens_finalizedBatchSkipsLimitsForUnregisteredNative() public {
        vm.prank(admin);
        nativeGateway.setWhitelistEnabled(true);
        // No mock — bridge defaults to "not preconfirmed".

        bytes32 messageHash = _relayReceiveNative(1 ether);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
    }

    function test_receiveNativeTokens_enforcesFastWithdrawalLimits() public {
        address nativeKey = nativeGateway.NATIVE_LIMIT_KEY();

        vm.prank(admin);
        fastWithdrawalList.registerToken(nativeKey, 2 ether, 3 ether);
        vm.prank(admin);
        nativeGateway.setWhitelistEnabled(true);
        _mockBridgePreconfirmed(true);

        // Within-limit receive of 1 ether succeeds and consumes the hourly/daily counters.
        bytes32 okHash = _relayReceiveNative(1 ether);
        assertEq(uint256(bridge.getReceivedMessage(okHash)), uint256(IFluentBridge.MessageStatus.Success));

        (uint256 currentHourWindow, uint256 hourlyUsed, uint256 currentDayWindow, uint256 dailyUsed) =
            fastWithdrawalList.getUsage(nativeKey);
        assertEq(currentHourWindow, block.timestamp / 1 hours);
        assertEq(hourlyUsed, 1 ether);
        assertEq(currentDayWindow, block.timestamp / 1 days);
        assertEq(dailyUsed, 1 ether);

        // Over-hourly-limit receive (1 + 2 > 2) must fail; counters must not advance.
        bytes32 overHourlyHash = _relayReceiveNative(2 ether);
        assertEq(uint256(bridge.getReceivedMessage(overHourlyHash)), uint256(IFluentBridge.MessageStatus.Failed));

        (, hourlyUsed, , dailyUsed) = fastWithdrawalList.getUsage(nativeKey);
        assertEq(hourlyUsed, 1 ether);
        assertEq(dailyUsed, 1 ether);

        // Next hour, hourly window resets; daily continues to accumulate.
        vm.warp(block.timestamp + 1 hours);
        bytes32 nextHourHash = _relayReceiveNative(2 ether);
        assertEq(uint256(bridge.getReceivedMessage(nextHourHash)), uint256(IFluentBridge.MessageStatus.Success));

        (, hourlyUsed, , dailyUsed) = fastWithdrawalList.getUsage(nativeKey);
        assertEq(hourlyUsed, 2 ether);
        assertEq(dailyUsed, 3 ether);

        // Disable hourly, keep daily at 3. Next receive of 1 would push daily to 4 → fail.
        vm.prank(admin);
        fastWithdrawalList.setLimit(nativeKey, 0, 3 ether);

        bytes32 overDailyHash = _relayReceiveNative(1 ether);
        assertEq(uint256(bridge.getReceivedMessage(overDailyHash)), uint256(IFluentBridge.MessageStatus.Failed));

        (, hourlyUsed, , dailyUsed) = fastWithdrawalList.getUsage(nativeKey);
        assertEq(hourlyUsed, 2 ether);
        assertEq(dailyUsed, 3 ether);
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
        vm.expectRevert(IGatewayBaseErrors.OnlyFluentBridge.selector);
        nativeGateway.receiveNativeTokens{value: 1 ether}(user, recipient, 1 ether);
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
        vm.expectRevert(IGatewayBaseErrors.InvalidRecipient.selector);
        nativeGateway.rescueNative(payable(address(0)), 1);
    }

    function test_setBridgeContract_updatesBridgeAddress() public {
        address newBridge = makeAddr("newBridge");

        vm.expectEmit(false, false, false, true, address(nativeGateway));
        emit IGatewayBaseEvents.BridgeContractUpdated(address(bridge), newBridge);
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
        emit IGatewayBaseEvents.ReceivedTokens(user, recipient, amount);

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

        // Previous owner can no longer perform admin actions
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, admin));
        nativeGateway.rescueNative(payable(recipient), 0);

        // New owner can perform admin actions
        vm.prank(newOwner);
        nativeGateway.rescueNative(payable(recipient), 0);
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

    function test_RevertIf_setBridgeContract_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IGatewayBaseErrors.ZeroAddressNotAllowed.selector, "newBridgeContract"));
        nativeGateway.setBridgeContract(address(0));
    }

    function test_RevertIf_setOtherSideGateway_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IGatewayBaseErrors.ZeroAddressNotAllowed.selector, "newOtherSideGateway"));
        nativeGateway.setOtherSideGateway(address(0));
    }

    function test_RevertIf_setOtherSideChainId_zero() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IGatewayBaseErrors.ZeroValueNotAllowed.selector, "newOtherSideChainId"));
        nativeGateway.setOtherSideChainId(0);
    }

    function test_bridgePause_blocksSendAndReceive() public {
        vm.prank(admin);
        (bool pauseOk, ) = address(bridge).call(abi.encodeWithSignature("pause()"));
        assertTrue(pauseOk, "bridge pause call failed");

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        nativeGateway.sendNativeTokens{value: 1 ether}(recipient);

        bytes memory message = abi.encodeCall(NativeGateway.receiveNativeTokens, (user, recipient, 1 ether));
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        vm.deal(address(bridge), 1 ether);
        vm.prank(relayer);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        bridge.receiveMessage(remoteGateway, address(nativeGateway), 1 ether, sourceChainId, sourceBlock, nonce, message);
    }
}
