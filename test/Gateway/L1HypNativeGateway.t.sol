// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {L1HypNativeGateway} from "../../contracts/gateways/L1HypNativeGateway.sol";
import {NativeGateway} from "../../contracts/gateways/NativeGateway.sol";
import {IL1HypNativeGateway, IHypNativeGatewayErrors, IHypNativeGatewayEvents} from "../../contracts/interfaces/gateways/IHypNativeGateway.sol";
import {IGatewayBaseErrors} from "../../contracts/interfaces/gateways/IGatewayBase.sol";
import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";

import {GatewayBase} from "./Base.t.sol";
import {MockTokenBridge} from "../mocks/MockTokenBridge.sol";

contract L1HypNativeGatewayTest is GatewayBase {
    L1HypNativeGateway internal l1Hyp;
    MockTokenBridge internal warpRoute;

    uint32 internal constant TEST_DOMAIN = 8453;
    bytes32 internal constant TEST_RECIPIENT = bytes32(uint256(uint160(0x1111111111111111111111111111111111111111)));
    /// @dev Dispatch gas portion of the warp route quote (`q[0].amount` in HypNative semantics).
    ///      Lower than `minHypFeeNative` users pay on L2 in tests, so reserve top-up isn't triggered
    ///      on the happy path.
    uint256 internal constant DEFAULT_DISPATCH_GAS = 0.005 ether;

    function setUp() public override {
        super.setUp();
        _deployBridge(0);
        _deployL1HypNativeGateway();
    }

    function _deployL1HypNativeGateway() internal {
        L1HypNativeGateway impl = new L1HypNativeGateway();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(L1HypNativeGateway.initialize, (admin, address(bridge))));
        l1Hyp = L1HypNativeGateway(payable(address(proxy)));

        vm.prank(admin);
        l1Hyp.setOtherSideGateway(remoteGateway);

        _registerGateway(address(l1Hyp));
        _registerGateway(remoteGateway);

        warpRoute = new MockTokenBridge();
        warpRoute.setDispatchGas(DEFAULT_DISPATCH_GAS);

        vm.prank(admin);
        l1Hyp.setWarpRoute(TEST_DOMAIN, address(warpRoute));

        // Wire the shared FastWithdrawalList so optimistic-withdrawal rate caps can be
        // exercised. The Hyperlane gateway charges against NativeGateway.NATIVE_LIMIT_KEY —
        // the same key used by NativeGateway — so the bucket is shared. Tests register the
        // key and enable the whitelist before flipping the bridge into Preconfirmed.
        _deployFastWithdrawalList();
        vm.prank(admin);
        l1Hyp.setFastWithdrawalList(address(fastWithdrawalList));
        bytes32 consumerRole = fastWithdrawalList.CONSUMER_ROLE();
        vm.prank(admin);
        fastWithdrawalList.grantRole(consumerRole, address(l1Hyp));
    }

    /// @dev Encodes and delivers a `receiveAndForwardNative` message via the bridge's
    ///      relayer path. Returns the message hash + transported value.
    function _relayReceive(uint256 transportedValue, uint256 amount, address fromGateway) internal returns (bytes32 messageHash) {
        bytes memory message = abi.encodeCall(IL1HypNativeGateway.receiveAndForwardNative, (TEST_DOMAIN, TEST_RECIPIENT, amount, user));
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        messageHash = _bridgeMessageHash(fromGateway, address(l1Hyp), transportedValue, sourceChainId, sourceBlock, nonce, message);

        vm.deal(address(bridge), address(bridge).balance + transportedValue);
        vm.prank(relayer);
        bridge.receiveMessage(fromGateway, address(l1Hyp), transportedValue, sourceChainId, sourceBlock, nonce, message);
    }

    function test_initialize_setsDefaults() public view {
        assertEq(l1Hyp.owner(), admin);
        assertEq(l1Hyp.getBridgeContract(), address(bridge));
        assertEq(l1Hyp.getOtherSideGateway(), remoteGateway);
        assertEq(l1Hyp.getWarpRoute(TEST_DOMAIN), address(warpRoute));
    }

    function test_receiveAndForwardNative_dispatchesToWarpRoute() public {
        uint256 amount = 1 ether;
        // Bridge transports amount + minHypFee. Quote total at delivery is amount + DEFAULT_DISPATCH_GAS
        // (q[0]=DEFAULT_DISPATCH_GAS, q[1]=amount, q[2]=0); transported is larger so surplus stays on gateway.
        uint256 transported = amount + 0.01 ether;

        bytes32 messageHash = _relayReceive(transported, amount, remoteGateway);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success), "should succeed");
        assertEq(warpRoute.lastDestination(), TEST_DOMAIN, "destination");
        assertEq(warpRoute.lastRecipient(), TEST_RECIPIENT, "recipient");
        assertEq(warpRoute.lastAmount(), amount, "amount");
        // Sum of all native quotes: dispatchGas + amount + 0 external.
        assertEq(warpRoute.lastValue(), amount + DEFAULT_DISPATCH_GAS, "value forwarded to warp route should equal sum of native quotes");
    }

    function test_receiveAndForwardNative_emitsHyperlaneTransferDispatched() public {
        uint256 amount = 1 ether;
        uint256 transported = amount + 0.01 ether;
        // Mock messageId — mirrors MockTokenBridge.transferRemote's keccak of (destination, recipient, amount, msg.value).
        // msg.value forwarded to the warp route equals the sum of all three native quotes (dispatchGas + amount + 0).
        bytes32 expectedMessageId = keccak256(abi.encode(TEST_DOMAIN, TEST_RECIPIENT, amount, amount + DEFAULT_DISPATCH_GAS));

        // Indexed topics: domain, recipient, originSender; messageId is non-indexed data.
        vm.expectEmit(true, true, true, true, address(l1Hyp));
        emit IHypNativeGatewayEvents.HyperlaneTransferDispatched(TEST_DOMAIN, TEST_RECIPIENT, amount, user, expectedMessageId);

        _relayReceive(transported, amount, remoteGateway);
    }

    function test_receiveAndForwardNative_topsUpFromReserveWhenQuoteExceedsTransported() public {
        uint256 amount = 1 ether;
        uint256 transported = amount; // no minHypFee transported
        // Total native required = dispatchGas + amount + 0; transported only covers `amount`,
        // so the 0.005 ether dispatchGas portion must come from the gateway reserve.
        warpRoute.setDispatchGas(0.005 ether);

        // Pre-fund the gateway reserve.
        vm.deal(address(l1Hyp), 1 ether);

        bytes32 messageHash = _relayReceive(transported, amount, remoteGateway);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(warpRoute.lastValue(), amount + 0.005 ether, "warp route should receive full quote sum");
        assertEq(address(l1Hyp).balance, 1 ether - 0.005 ether, "reserve depleted by top-up");
    }

    function test_receiveAndForwardNative_marksFailed_whenReserveDepleted() public {
        uint256 amount = 1 ether;
        // Transport exact `amount`; dispatchGas of 1 ether requires reserve top-up beyond what's funded.
        warpRoute.setDispatchGas(1 ether);

        bytes32 messageHash = _relayReceive(amount, amount, remoteGateway);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed), "ReserveDepleted should fail");
    }

    /// @dev Finalized batches bypass the rate cap entirely — `_consumeLimit` short-circuits on
    ///      `!_isFromPreconfirmedBatch()` regardless of whether the whitelist is on or off.
    function test_receiveAndForwardNative_finalizedBatch_skipsLimits() public {
        uint256 amount = 1 ether;
        uint256 transported = amount + 0.01 ether;

        vm.prank(admin);
        l1Hyp.setWhitelistEnabled(true);
        // No `_mockBridgePreconfirmed(true)` — bridge defaults to Finalized.

        bytes32 messageHash = _relayReceive(transported, amount, remoteGateway);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success), "finalized batch should pass");
    }

    /// @dev With the whitelist disabled, `_consumeLimit` short-circuits before reading the
    ///      registry — Preconfirmed batches pass through without any rate cap.
    function test_receiveAndForwardNative_preconfirmedBatch_whitelistOff_passes() public {
        uint256 amount = 1 ether;
        uint256 transported = amount + 0.01 ether;

        _mockBridgePreconfirmed(true);
        // Whitelist not enabled.
        bytes32 messageHash = _relayReceive(transported, amount, remoteGateway);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success), "whitelist off should pass");
    }

    /// @dev Whitelist enabled + Preconfirmed batch + NATIVE_LIMIT_KEY unregistered → the
    ///      gateway must mark the receive Failed (FastWithdrawalNotAllowed).
    function test_receiveAndForwardNative_preconfirmedBatch_marksFailedWhenKeyNotRegistered() public {
        address nativeKey = l1Hyp.NATIVE_LIMIT_KEY();
        uint256 amount = 1 ether;
        uint256 transported = amount + 0.01 ether;

        vm.prank(admin);
        l1Hyp.setWhitelistEnabled(true);
        _mockBridgePreconfirmed(true);

        bytes32 messageHash = _relayReceive(transported, amount, remoteGateway);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed), "unregistered key must mark Failed");

        // Unregistered bucket: usage stays at zero.
        (, uint256 hourlyUsed, , uint256 dailyUsed) = fastWithdrawalList.getUsage(nativeKey);
        assertEq(hourlyUsed, 0, "hourly usage must stay zero on rejection");
        assertEq(dailyUsed, 0, "daily usage must stay zero on rejection");
    }

    /// @dev Happy path under the optimistic policy: NATIVE_LIMIT_KEY registered, whitelist on,
    ///      Preconfirmed batch, amount within cap → success, counters advance.
    function test_receiveAndForwardNative_preconfirmedBatch_consumesLimitWithinCap() public {
        address nativeKey = l1Hyp.NATIVE_LIMIT_KEY();
        uint256 amount = 1 ether;
        uint256 transported = amount + 0.01 ether;

        vm.prank(admin);
        fastWithdrawalList.registerToken(nativeKey, 2 ether, 3 ether);
        vm.prank(admin);
        l1Hyp.setWhitelistEnabled(true);
        _mockBridgePreconfirmed(true);

        bytes32 messageHash = _relayReceive(transported, amount, remoteGateway);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success), "within-cap should succeed");

        (uint256 currentHourWindow, uint256 hourlyUsed, uint256 currentDayWindow, uint256 dailyUsed) =
            fastWithdrawalList.getUsage(nativeKey);
        assertEq(currentHourWindow, block.timestamp / 1 hours, "hour window mismatch");
        assertEq(hourlyUsed, 1 ether, "hourly usage advanced by amount");
        assertEq(currentDayWindow, block.timestamp / 1 days, "day window mismatch");
        assertEq(dailyUsed, 1 ether, "daily usage advanced by amount");
    }

    /// @dev Cap breach within the hourly window — second receive that would push over the cap
    ///      must be marked Failed and counters must not advance.
    function test_receiveAndForwardNative_preconfirmedBatch_marksFailedWhenHourlyCapExceeded() public {
        address nativeKey = l1Hyp.NATIVE_LIMIT_KEY();

        vm.prank(admin);
        fastWithdrawalList.registerToken(nativeKey, 2 ether, 3 ether);
        vm.prank(admin);
        l1Hyp.setWhitelistEnabled(true);
        _mockBridgePreconfirmed(true);

        // First receive of 1 ether passes.
        bytes32 firstHash = _relayReceive(1 ether + 0.01 ether, 1 ether, remoteGateway);
        assertEq(uint256(bridge.getReceivedMessage(firstHash)), uint256(IFluentBridge.MessageStatus.Success), "within-cap first leg should succeed");

        // Second receive of 2 ether (cumulative 3 > cap 2) must fail.
        bytes32 overHash = _relayReceive(2 ether + 0.01 ether, 2 ether, remoteGateway);
        assertEq(uint256(bridge.getReceivedMessage(overHash)), uint256(IFluentBridge.MessageStatus.Failed), "over-cap second leg must fail");

        (, uint256 hourlyUsed, , uint256 dailyUsed) = fastWithdrawalList.getUsage(nativeKey);
        assertEq(hourlyUsed, 1 ether, "rolled-back consume must not advance hourly");
        assertEq(dailyUsed, 1 ether, "rolled-back consume must not advance daily");
    }

    /// @dev Hourly window resets after one hour; daily window continues accumulating across
    ///      the boundary — mirrors `NativeGateway.t.sol`.
    function test_receiveAndForwardNative_preconfirmedBatch_dailyCapResetsAfterHour() public {
        address nativeKey = l1Hyp.NATIVE_LIMIT_KEY();

        vm.prank(admin);
        fastWithdrawalList.registerToken(nativeKey, 2 ether, 3 ether);
        vm.prank(admin);
        l1Hyp.setWhitelistEnabled(true);
        _mockBridgePreconfirmed(true);

        _relayReceive(1 ether + 0.01 ether, 1 ether, remoteGateway);

        // Time-warp into the next hour.
        vm.warp(block.timestamp + 1 hours);

        // Now hourly resets to zero, so 2 ether passes within the fresh hourly window even
        // though the cumulative daily (1 + 2 = 3) is exactly at the daily cap.
        bytes32 nextHash = _relayReceive(2 ether + 0.01 ether, 2 ether, remoteGateway);
        assertEq(uint256(bridge.getReceivedMessage(nextHash)), uint256(IFluentBridge.MessageStatus.Success), "fresh hour window should accept up to cap");

        (, uint256 hourlyUsed, , uint256 dailyUsed) = fastWithdrawalList.getUsage(nativeKey);
        assertEq(hourlyUsed, 2 ether, "hourly usage after window reset");
        assertEq(dailyUsed, 3 ether, "daily usage accumulated across the boundary");
    }

    /// @dev The defining property of the shared-bucket design: NativeGateway and
    ///      L1HypNativeGateway debit the SAME NATIVE_LIMIT_KEY bucket, so the combined per-
    ///      window outflow across both gateways stays bounded by ONE configured cap. If we
    ///      used a separate key on L1HypNativeGateway, an attacker could drain 2× the cap by
    ///      exploiting both gateways in parallel within one Preconfirmed window.
    function test_sharedBucket_NativeGatewayPlusL1Hyp() public {
        address nativeKey = l1Hyp.NATIVE_LIMIT_KEY();

        // Deploy a separate NativeGateway against the SAME bridge + fastWithdrawalList.
        NativeGateway impl = new NativeGateway();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(NativeGateway.initialize, (admin, address(bridge))));
        NativeGateway nativeGateway = NativeGateway(payable(address(proxy)));
        vm.prank(admin);
        nativeGateway.setOtherSideGateway(remoteGateway);
        _registerGateway(address(nativeGateway));

        // Wire NativeGateway as a second consumer on the shared list.
        vm.prank(admin);
        nativeGateway.setFastWithdrawalList(address(fastWithdrawalList));
        bytes32 consumerRole = fastWithdrawalList.CONSUMER_ROLE();
        vm.prank(admin);
        fastWithdrawalList.grantRole(consumerRole, address(nativeGateway));

        // Hourly cap = 2 ether; enable whitelist on BOTH gateways; Preconfirmed batch.
        vm.prank(admin);
        fastWithdrawalList.registerToken(nativeKey, 2 ether, 10 ether);
        vm.prank(admin);
        nativeGateway.setWhitelistEnabled(true);
        vm.prank(admin);
        l1Hyp.setWhitelistEnabled(true);
        _mockBridgePreconfirmed(true);

        // 1 ETH withdrawal via NativeGateway → Success, bucket usage = 1 ether.
        bytes memory nativeMsg = abi.encodeCall(NativeGateway.receiveNativeTokens, (user, recipient, 1 ether));
        uint256 nonce0 = bridge.getReceivedNonce();
        uint256 srcBlock0 = nextSourceBlock++;
        bytes32 nativeHash = _bridgeMessageHash(remoteGateway, address(nativeGateway), 1 ether, sourceChainId, srcBlock0, nonce0, nativeMsg);
        vm.deal(address(bridge), address(bridge).balance + 1 ether);
        vm.prank(relayer);
        bridge.receiveMessage(remoteGateway, address(nativeGateway), 1 ether, sourceChainId, srcBlock0, nonce0, nativeMsg);
        assertEq(uint256(bridge.getReceivedMessage(nativeHash)), uint256(IFluentBridge.MessageStatus.Success), "first leg (NativeGateway) should succeed");

        (, uint256 hourlyAfterNative, , ) = fastWithdrawalList.getUsage(nativeKey);
        assertEq(hourlyAfterNative, 1 ether, "first leg consumed shared bucket");

        // 1.5 ETH forward via L1HypNativeGateway → would push bucket to 2.5 > cap 2 → Failed.
        bytes32 hypHash = _relayReceive(1.5 ether + 0.01 ether, 1.5 ether, remoteGateway);
        assertEq(uint256(bridge.getReceivedMessage(hypHash)), uint256(IFluentBridge.MessageStatus.Failed), "shared bucket must reject second leg");

        // Bucket usage unchanged — proves the second leg was rejected at consume time.
        (, uint256 hourlyAfterHyp, , ) = fastWithdrawalList.getUsage(nativeKey);
        assertEq(hourlyAfterHyp, 1 ether, "rejected consume must not advance bucket");
    }

    /// @dev Canonical `HypNative.quoteTransferRemote` returns exactly 3 entries. A shorter
    ///      array would let the gateway read past bounds; the explicit guard surfaces a clean
    ///      `MalformedQuote` instead.
    function test_receiveAndForwardNative_marksFailed_whenQuoteLengthBelowThree() public {
        uint256 amount = 1 ether;
        uint256 transported = amount + 0.01 ether;

        warpRoute.setQuoteLengthOverride(2);
        bytes32 messageHash = _relayReceive(transported, amount, remoteGateway);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed), "length 2 must be rejected");
    }

    /// @dev A longer-than-canonical `Quote[]` is equally suspect — the gateway treats anything
    ///      other than exactly 3 entries as a non-HypNative variant and refuses to dispatch.
    function test_receiveAndForwardNative_marksFailed_whenQuoteLengthAboveThree() public {
        uint256 amount = 1 ether;
        uint256 transported = amount + 0.01 ether;

        warpRoute.setQuoteLengthOverride(4);
        bytes32 messageHash = _relayReceive(transported, amount, remoteGateway);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed), "length 4 must be rejected");
    }

    function test_receiveAndForwardNative_marksFailed_whenDomainUnsupported() public {
        // Encode for a different domain than the one configured.
        uint32 otherDomain = 42161; // arbitrum
        uint256 amount = 1 ether;
        uint256 transported = amount + 0.01 ether;

        bytes memory message = abi.encodeCall(IL1HypNativeGateway.receiveAndForwardNative, (otherDomain, TEST_RECIPIENT, amount, user));
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        bytes32 messageHash = _bridgeMessageHash(remoteGateway, address(l1Hyp), transported, sourceChainId, sourceBlock, nonce, message);

        vm.deal(address(bridge), address(bridge).balance + transported);
        vm.prank(relayer);
        bridge.receiveMessage(remoteGateway, address(l1Hyp), transported, sourceChainId, sourceBlock, nonce, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed), "unsupported domain should fail");
    }

    function test_receiveAndForwardNative_marksFailed_whenSenderNotPeer() public {
        address wrongRemote = makeAddr("wrongRemote");
        uint256 amount = 1 ether;
        uint256 transported = amount + 0.01 ether;

        bytes32 messageHash = _relayReceive(transported, amount, wrongRemote);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed), "wrong sender should fail");
    }

    function test_receiveAndForwardNative_marksFailed_whenZeroRecipient() public {
        uint256 amount = 1 ether;
        uint256 transported = amount + 0.01 ether;

        bytes memory message = abi.encodeCall(IL1HypNativeGateway.receiveAndForwardNative, (TEST_DOMAIN, bytes32(0), amount, user));
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        bytes32 messageHash = _bridgeMessageHash(remoteGateway, address(l1Hyp), transported, sourceChainId, sourceBlock, nonce, message);

        vm.deal(address(bridge), address(bridge).balance + transported);
        vm.prank(relayer);
        bridge.receiveMessage(remoteGateway, address(l1Hyp), transported, sourceChainId, sourceBlock, nonce, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_RevertIf_receiveAndForwardNative_callerNotBridge() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(IGatewayBaseErrors.OnlyFluentBridge.selector);
        l1Hyp.receiveAndForwardNative{value: 1 ether}(TEST_DOMAIN, TEST_RECIPIENT, 1 ether, user);
    }

    function test_setWarpRoute_updatesAndEmits() public {
        address newRoute = address(new MockTokenBridge());

        vm.expectEmit(true, true, true, true, address(l1Hyp));
        emit IHypNativeGatewayEvents.WarpRouteUpdated(TEST_DOMAIN, address(warpRoute), newRoute);

        vm.prank(admin);
        l1Hyp.setWarpRoute(TEST_DOMAIN, newRoute);

        assertEq(l1Hyp.getWarpRoute(TEST_DOMAIN), newRoute);
    }

    function test_RevertIf_setWarpRoute_warpRouteNotAContract() public {
        address eoa = makeAddr("eoa");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IHypNativeGatewayErrors.WarpRouteNotAContract.selector, eoa));
        l1Hyp.setWarpRoute(TEST_DOMAIN, eoa);
    }

    function test_setWarpRoute_clearsRouteWhenZero() public {
        // address(0) is the documented "clear" sentinel and must bypass the code-length check.
        vm.prank(admin);
        l1Hyp.setWarpRoute(TEST_DOMAIN, address(0));
        assertEq(l1Hyp.getWarpRoute(TEST_DOMAIN), address(0));
    }

    function test_RevertIf_setWarpRoute_callerNotOwner() public {
        vm.prank(stranger());
        vm.expectRevert();
        l1Hyp.setWarpRoute(TEST_DOMAIN, address(0xdead));
    }

    function test_rescueNative_transfersBalance() public {
        vm.deal(address(l1Hyp), 1 ether);
        uint256 beforeRecipient = recipient.balance;

        vm.prank(admin);
        l1Hyp.rescueNative(payable(recipient), 0.4 ether);

        assertEq(recipient.balance - beforeRecipient, 0.4 ether);
        assertEq(address(l1Hyp).balance, 0.6 ether);
    }

    function test_RevertIf_rescueNative_zeroRecipient() public {
        vm.prank(admin);
        vm.expectRevert(IGatewayBaseErrors.InvalidRecipient.selector);
        l1Hyp.rescueNative(payable(address(0)), 1);
    }

    function test_RevertIf_rescueNative_callerNotOwner() public {
        vm.prank(stranger());
        vm.expectRevert();
        l1Hyp.rescueNative(payable(recipient), 1);
    }

    /// @dev Helper because `GatewayBase.t.sol` doesn't declare `stranger`.
    function stranger() internal returns (address) {
        return makeAddr("stranger");
    }
}
