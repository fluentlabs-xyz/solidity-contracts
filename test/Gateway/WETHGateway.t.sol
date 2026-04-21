// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {WETHGateway} from "../../contracts/gateways/WETHGateway.sol";
import {NativeGateway} from "../../contracts/gateways/NativeGateway.sol";
import {IFluentBridge, IFluentBridgeErrors} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {IGatewayBaseErrors, IGatewayBaseEvents} from "../../contracts/interfaces/gateways/IGatewayBase.sol";
import {IWETHGateway, IWETHGatewayErrors, IWETHGatewayEvents} from "../../contracts/interfaces/gateways/IWETHGateway.sol";
import {
    MockWETH,
    BadWrapMockWETH,
    BadUnwrapMockWETH,
    FeeOnTransferMockWETH,
    MockUniversalWETH
} from "../../contracts/mocks/MockWETH.sol";
import {GatewayBase} from "./Base.t.sol";

contract WETHGatewayTest is GatewayBase {
    WETHGateway internal wethGateway;
    MockWETH internal weth;

    function setUp() public override {
        super.setUp();
        _deployBridge(0);
        _deployWETHGateway();
    }

    function _deployWETHGateway() internal {
        weth = new MockWETH();

        WETHGateway impl = new WETHGateway();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(WETHGateway.initialize, (admin, address(bridge), address(weth)))
        );
        wethGateway = WETHGateway(payable(address(proxy)));

        vm.prank(admin);
        wethGateway.setOtherSideGateway(remoteGateway);

        // Both the local gateway (receive path) and the remote peer (outbound `sendMessage`
        // admission check) must be in the bridge's gateway registry.
        _registerGateway(address(wethGateway));
        _registerGateway(remoteGateway);

        // Wire the shared FastWithdrawalList so the optimistic-withdrawal policy can be
        // exercised. WETH receives debit the NATIVE bucket by design.
        _deployFastWithdrawalList();
        vm.prank(admin);
        wethGateway.setFastWithdrawalList(address(fastWithdrawalList));
        bytes32 consumerRole = fastWithdrawalList.CONSUMER_ROLE();
        vm.prank(admin);
        fastWithdrawalList.grantRole(consumerRole, address(wethGateway));
    }

    // ---------- Helpers ----------

    function _fundUserWithWETH(uint256 amount) internal {
        vm.deal(user, amount);
        vm.prank(user);
        weth.deposit{value: amount}();
    }

    function _relayReceiveWETH(uint256 amount) internal returns (bytes32 messageHash) {
        bytes memory message = abi.encodeCall(IWETHGateway.receiveWETH, (user, recipient, amount));
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        messageHash = _bridgeMessageHash(remoteGateway, address(wethGateway), amount, sourceChainId, sourceBlock, nonce, message);
        vm.deal(address(bridge), address(bridge).balance + amount);
        vm.prank(relayer);
        bridge.receiveMessage(remoteGateway, address(wethGateway), amount, sourceChainId, sourceBlock, nonce, message);
    }

    // ---------- Initialization ----------

    function test_initialize_setsDefaults() public view {
        assertEq(wethGateway.owner(), admin);
        assertEq(wethGateway.getBridgeContract(), address(bridge));
        assertEq(wethGateway.getOtherSideGateway(), remoteGateway);
        assertEq(wethGateway.getWETH(), address(weth));
    }

    /// @dev The fast-withdraw key MUST be byte-identical to {NativeGateway.NATIVE_LIMIT_KEY}
    ///      — otherwise ETH and WETH would debit separate buckets and the whole point of the
    ///      shared cap would be defeated. This lock-in test catches accidental divergence.
    function test_NATIVE_LIMIT_KEY_matchesNativeGateway() public {
        NativeGateway nativeImpl = new NativeGateway();
        assertEq(wethGateway.NATIVE_LIMIT_KEY(), nativeImpl.NATIVE_LIMIT_KEY());
    }

    /// @dev L2 bootstrap: proxy may be initialized with `weth = 0` so the gateway address
    ///      is fixed before Universal-token CREATE2 deployment; {setWETH} completes wiring.
    function test_initialize_zeroWETH_thenSetWETH() public {
        WETHGateway impl = new WETHGateway();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(WETHGateway.initialize, (admin, address(bridge), address(0)))
        );
        WETHGateway g = WETHGateway(payable(address(proxy)));
        assertEq(g.getWETH(), address(0));

        vm.prank(admin);
        g.setWETH(address(weth));
        assertEq(g.getWETH(), address(weth));
    }

    function test_RevertIf_sendWETH_WETHNotConfigured_beforeSetWETH() public {
        WETHGateway impl = new WETHGateway();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(WETHGateway.initialize, (admin, address(bridge), address(0)))
        );
        WETHGateway g = WETHGateway(payable(address(proxy)));
        vm.prank(admin);
        g.setOtherSideGateway(remoteGateway);

        vm.prank(user);
        vm.expectRevert(IWETHGatewayErrors.WETHNotConfigured.selector);
        g.sendWETH(recipient, 1 ether);
    }

    // ---------- sendWETH ----------

    function test_sendWETH_unwrapsAndLocksNativeInBridge() public {
        uint256 amount = 1 ether;
        _fundUserWithWETH(amount);

        vm.prank(user);
        weth.approve(address(wethGateway), amount);

        uint256 bridgeBalBefore = address(bridge).balance;

        vm.prank(user);
        wethGateway.sendWETH(recipient, amount);

        // Bridge now holds the native value representing the bridged WETH
        assertEq(address(bridge).balance - bridgeBalBefore, amount);
        // User's WETH is burned via `withdraw`
        assertEq(weth.balanceOf(user), 0);
        // Gateway must not retain any WETH or ETH after a successful send
        assertEq(weth.balanceOf(address(wethGateway)), 0);
        assertEq(address(wethGateway).balance, 0);
    }

    function test_RevertIf_sendWETH_zeroAmount() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IGatewayBaseErrors.ZeroValueNotAllowed.selector, "amount"));
        wethGateway.sendWETH(recipient, 0);
    }

    function test_RevertIf_sendWETH_zeroRecipient() public {
        vm.prank(user);
        vm.expectRevert(IGatewayBaseErrors.InvalidRecipient.selector);
        wethGateway.sendWETH(address(0), 1 ether);
    }

    function test_RevertIf_sendWETH_nonZeroFeeAttached() public {
        uint256 amount = 1 ether;
        _fundUserWithWETH(amount);
        vm.prank(user);
        weth.approve(address(wethGateway), amount);
        // Bridge is initialized with zero fee in tests, so any attached ETH must be rejected.
        vm.deal(user, 1 wei);
        vm.prank(user);
        vm.expectRevert(IGatewayBaseErrors.ExactFeeRequired.selector);
        wethGateway.sendWETH{value: 1 wei}(recipient, amount);
    }

    function test_RevertIf_sendWETH_withoutApproval() public {
        uint256 amount = 1 ether;
        _fundUserWithWETH(amount);
        // No approve.
        vm.prank(user);
        // OZ ERC20 reverts with `ERC20InsufficientAllowance(spender, current, needed)`.
        // The exact error data depends on OZ version; use a loose expectRevert.
        vm.expectRevert();
        wethGateway.sendWETH(recipient, amount);
    }

    function test_RevertIf_sendWETH_otherSideGatewayUnset() public {
        WETHGateway impl = new WETHGateway();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(WETHGateway.initialize, (admin, address(bridge), address(weth)))
        );
        WETHGateway freshGateway = WETHGateway(payable(address(proxy)));
        // No `setOtherSideGateway` call → stored as zero.
        uint256 amount = 1 ether;
        _fundUserWithWETH(amount);
        vm.prank(user);
        weth.approve(address(freshGateway), amount);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IGatewayBaseErrors.ZeroAddressNotAllowed.selector, "getOtherSideGateway"));
        freshGateway.sendWETH(recipient, amount);
    }

    function test_RevertIf_sendWETH_unwrapAccountingMismatch() public {
        // Swap the gateway's WETH to a broken one that returns less ETH on withdraw.
        BadUnwrapMockWETH bad = new BadUnwrapMockWETH();
        vm.prank(admin);
        wethGateway.setWETH(address(bad));

        uint256 amount = 1 ether;
        vm.deal(user, amount);
        vm.prank(user);
        bad.deposit{value: amount}();
        vm.prank(user);
        bad.approve(address(wethGateway), amount);

        vm.prank(user);
        vm.expectRevert(IWETHGatewayErrors.UnwrapAccountingMismatch.selector);
        wethGateway.sendWETH(recipient, amount);
    }

    // ---------- receiveWETH ----------

    function test_receiveWETH_viaBridge_wrapsAndForwardsToRecipient() public {
        uint256 amount = 2 ether;
        uint256 recipientWETHBefore = weth.balanceOf(recipient);

        bytes32 messageHash = _relayReceiveWETH(amount);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(weth.balanceOf(recipient) - recipientWETHBefore, amount);
        // Gateway must not retain any WETH or ETH after a successful receive.
        assertEq(weth.balanceOf(address(wethGateway)), 0);
        assertEq(address(wethGateway).balance, 0);
    }

    function test_receiveWETH_emitsReceivedTokens() public {
        uint256 amount = 1 ether;
        bytes memory message = abi.encodeCall(IWETHGateway.receiveWETH, (user, recipient, amount));
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        vm.deal(address(bridge), amount);

        vm.expectEmit(true, true, false, true, address(wethGateway));
        emit IGatewayBaseEvents.ReceivedTokens(user, recipient, amount);

        vm.prank(relayer);
        bridge.receiveMessage(remoteGateway, address(wethGateway), amount, sourceChainId, sourceBlock, nonce, message);
    }

    function test_receiveWETH_directCall_revertsOnlyFluentBridge() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(IGatewayBaseErrors.OnlyFluentBridge.selector);
        wethGateway.receiveWETH{value: 1 ether}(user, recipient, 1 ether);
    }

    function test_receiveWETH_wrongGatewaySender_marksFailed() public {
        uint256 amount = 1 ether;
        bytes memory message = abi.encodeCall(IWETHGateway.receiveWETH, (user, recipient, amount));
        address wrongRemoteGateway = makeAddr("wrongRemoteGateway");
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        bytes32 messageHash = _bridgeMessageHash(
            wrongRemoteGateway,
            address(wethGateway),
            amount,
            sourceChainId,
            sourceBlock,
            nonce,
            message
        );
        vm.deal(address(bridge), amount);

        // Register the wrong peer on the bridge so the bridge doesn't short-circuit on
        // GatewayNotWhitelisted — we want the failure to surface *inside* the gateway.
        _registerGateway(wrongRemoteGateway);

        vm.prank(relayer);
        bridge.receiveMessage(wrongRemoteGateway, address(wethGateway), amount, sourceChainId, sourceBlock, nonce, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
        // No WETH must have been minted to anyone on a failed delivery.
        assertEq(weth.balanceOf(recipient), 0);
    }

    function test_receiveWETH_valuePayloadMismatch_marksFailed() public {
        uint256 bridgeValue = 1 ether;
        uint256 payloadAmount = 2 ether;
        bytes memory message = abi.encodeCall(IWETHGateway.receiveWETH, (user, recipient, payloadAmount));
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        bytes32 messageHash = _bridgeMessageHash(
            remoteGateway,
            address(wethGateway),
            bridgeValue,
            sourceChainId,
            sourceBlock,
            nonce,
            message
        );
        vm.deal(address(bridge), bridgeValue);

        vm.prank(relayer);
        bridge.receiveMessage(remoteGateway, address(wethGateway), bridgeValue, sourceChainId, sourceBlock, nonce, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_receiveWETH_zeroRecipient_marksFailed() public {
        uint256 amount = 1 ether;
        bytes memory message = abi.encodeCall(IWETHGateway.receiveWETH, (user, address(0), amount));
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        bytes32 messageHash = _bridgeMessageHash(remoteGateway, address(wethGateway), amount, sourceChainId, sourceBlock, nonce, message);
        vm.deal(address(bridge), amount);

        vm.prank(relayer);
        bridge.receiveMessage(remoteGateway, address(wethGateway), amount, sourceChainId, sourceBlock, nonce, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_receiveWETH_wrapAccountingMismatch_marksFailed() public {
        BadWrapMockWETH bad = new BadWrapMockWETH();
        vm.prank(admin);
        wethGateway.setWETH(address(bad));

        uint256 amount = 1 ether;
        bytes memory message = abi.encodeCall(IWETHGateway.receiveWETH, (user, recipient, amount));
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        bytes32 messageHash = _bridgeMessageHash(remoteGateway, address(wethGateway), amount, sourceChainId, sourceBlock, nonce, message);
        vm.deal(address(bridge), amount);

        vm.prank(relayer);
        bridge.receiveMessage(remoteGateway, address(wethGateway), amount, sourceChainId, sourceBlock, nonce, message);

        // Gateway revert must surface as a bridge-level Failed status; user gets no WETH.
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
        assertEq(bad.balanceOf(recipient), 0);
    }

    function test_receiveWETH_transferAccountingMismatch_marksFailed() public {
        FeeOnTransferMockWETH bad = new FeeOnTransferMockWETH();
        vm.prank(admin);
        wethGateway.setWETH(address(bad));

        uint256 amount = 1 ether;
        bytes memory message = abi.encodeCall(IWETHGateway.receiveWETH, (user, recipient, amount));
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        bytes32 messageHash = _bridgeMessageHash(remoteGateway, address(wethGateway), amount, sourceChainId, sourceBlock, nonce, message);
        vm.deal(address(bridge), amount);

        vm.prank(relayer);
        bridge.receiveMessage(remoteGateway, address(wethGateway), amount, sourceChainId, sourceBlock, nonce, message);

        // Non-canonical fee-on-transfer token must be rejected to avoid short-changing recipient.
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
        assertEq(bad.balanceOf(recipient), 0);
    }

    // ---------- FastWithdrawalList integration (shared NATIVE bucket) ----------

    function test_receiveWETH_marksFailedWhenPreconfirmedAndNativeNotInFastList() public {
        vm.prank(admin);
        wethGateway.setWhitelistEnabled(true);
        _mockBridgePreconfirmed(true);

        bytes32 messageHash = _relayReceiveWETH(1 ether);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));

        address nativeKey = wethGateway.NATIVE_LIMIT_KEY();
        (, uint256 hourlyUsed, , uint256 dailyUsed) = fastWithdrawalList.getUsage(nativeKey);
        assertEq(hourlyUsed, 0);
        assertEq(dailyUsed, 0);
    }

    function test_receiveWETH_finalizedBatchSkipsLimitsForUnregisteredNative() public {
        vm.prank(admin);
        wethGateway.setWhitelistEnabled(true);
        // No `_mockBridgePreconfirmed(true)` — default "not preconfirmed" path.

        bytes32 messageHash = _relayReceiveWETH(1 ether);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
    }

    function test_receiveWETH_enforcesFastWithdrawalLimits_sharedBucketWithETH() public {
        address nativeKey = wethGateway.NATIVE_LIMIT_KEY();

        vm.prank(admin);
        fastWithdrawalList.registerToken(nativeKey, 2 ether, 3 ether);
        vm.prank(admin);
        wethGateway.setWhitelistEnabled(true);
        _mockBridgePreconfirmed(true);

        // 1 ether receive succeeds; consumes 1 ether of the shared native bucket.
        bytes32 okHash = _relayReceiveWETH(1 ether);
        assertEq(uint256(bridge.getReceivedMessage(okHash)), uint256(IFluentBridge.MessageStatus.Success));

        (, uint256 hourlyUsed, , uint256 dailyUsed) = fastWithdrawalList.getUsage(nativeKey);
        assertEq(hourlyUsed, 1 ether);
        assertEq(dailyUsed, 1 ether);

        // 2 ether receive would push hourly to 3 > cap 2 — must fail without advancing counters.
        bytes32 overHash = _relayReceiveWETH(2 ether);
        assertEq(uint256(bridge.getReceivedMessage(overHash)), uint256(IFluentBridge.MessageStatus.Failed));

        (, hourlyUsed, , dailyUsed) = fastWithdrawalList.getUsage(nativeKey);
        assertEq(hourlyUsed, 1 ether);
        assertEq(dailyUsed, 1 ether);
    }

    // ---------- Admin & rescue ----------

    function test_setWETH_updatesAndEmits() public {
        MockWETH other = new MockWETH();
        vm.expectEmit(true, true, false, true, address(wethGateway));
        emit IWETHGatewayEvents.WETHUpdated(address(weth), address(other));
        vm.prank(admin);
        wethGateway.setWETH(address(other));
        assertEq(wethGateway.getWETH(), address(other));
    }

    function test_RevertIf_setWETH_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IGatewayBaseErrors.ZeroAddressNotAllowed.selector, "weth"));
        wethGateway.setWETH(address(0));
    }

    function test_RevertIf_setWETH_notOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        wethGateway.setWETH(address(1));
    }

    function test_rescueNative_transfersBalance() public {
        vm.deal(address(wethGateway), 1 ether);
        uint256 before_ = recipient.balance;
        vm.prank(admin);
        wethGateway.rescueNative(payable(recipient), 0.4 ether);
        assertEq(recipient.balance - before_, 0.4 ether);
        assertEq(address(wethGateway).balance, 0.6 ether);
    }

    function test_RevertIf_rescueNative_zeroRecipient() public {
        vm.prank(admin);
        vm.expectRevert(IGatewayBaseErrors.InvalidRecipient.selector);
        wethGateway.rescueNative(payable(address(0)), 1);
    }

    function test_rescueWETH_transfersBalance() public {
        uint256 amount = 2 ether;
        vm.deal(address(wethGateway), amount);
        // Fund the gateway with WETH by wrapping directly (also covers `receive()`).
        vm.prank(address(wethGateway));
        weth.deposit{value: amount}();
        assertEq(weth.balanceOf(address(wethGateway)), amount);

        vm.prank(admin);
        wethGateway.rescueWETH(recipient, 0.5 ether);
        assertEq(weth.balanceOf(recipient), 0.5 ether);
        assertEq(weth.balanceOf(address(wethGateway)), 1.5 ether);
    }

    function test_RevertIf_rescueWETH_zeroRecipient() public {
        vm.prank(admin);
        vm.expectRevert(IGatewayBaseErrors.InvalidRecipient.selector);
        wethGateway.rescueWETH(address(0), 1);
    }

    function test_RevertIf_rescueWETH_notOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        wethGateway.rescueWETH(recipient, 1);
    }

    // ---------- Bridge lifecycle ----------

    function test_bridgePause_blocksSendAndReceive() public {
        vm.prank(admin);
        (bool pauseOk, ) = address(bridge).call(abi.encodeWithSignature("pause()"));
        assertTrue(pauseOk, "bridge pause call failed");

        uint256 amount = 1 ether;
        _fundUserWithWETH(amount);
        vm.prank(user);
        weth.approve(address(wethGateway), amount);

        vm.prank(user);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        wethGateway.sendWETH(recipient, amount);

        bytes memory message = abi.encodeCall(IWETHGateway.receiveWETH, (user, recipient, amount));
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        vm.deal(address(bridge), amount);
        vm.prank(relayer);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        bridge.receiveMessage(remoteGateway, address(wethGateway), amount, sourceChainId, sourceBlock, nonce, message);
    }

    // ---------- `receive()` ----------

    /// @dev Bare ETH must be accepted: {WETH.withdraw} refunds native value via a raw
    ///      call during `sendWETH`, and `receiveFailedMessage` retries re-deliver ETH.
    function test_receive_acceptsDirectEth() public {
        vm.deal(user, 2 ether);
        uint256 beforeBal = address(wethGateway).balance;
        vm.prank(user);
        (bool ok, ) = address(wethGateway).call{value: 0.25 ether}("");
        assertTrue(ok, "direct ETH transfer to WETH gateway failed");
        assertEq(address(wethGateway).balance - beforeBal, 0.25 ether);
    }

    // ---------- Round-trip ----------

    /// @dev Full WETH→ETH→bridge→ETH→WETH round trip inside one test, mirroring the mental
    ///      model from the contract NatSpec. Fails loudly if anything breaks the 1:1 promise.
    function test_roundTrip_WETH_in_WETH_out() public {
        uint256 amount = 3 ether;
        _fundUserWithWETH(amount);

        vm.prank(user);
        weth.approve(address(wethGateway), amount);

        // Send leg: user's WETH is burned, bridge holds the native value.
        vm.prank(user);
        wethGateway.sendWETH(recipient, amount);
        assertEq(weth.balanceOf(user), 0);
        assertEq(address(bridge).balance, amount);

        // Delivery leg: relayer delivers, recipient ends up with the same amount of WETH.
        bytes32 hash_ = _relayReceiveWETH(amount);
        assertEq(uint256(bridge.getReceivedMessage(hash_)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(weth.balanceOf(recipient), amount);
    }

    // ====================================================================================
    // L2 / Universal-WETH scenario
    //
    // Once the Fluent-L2 precompile upgrade exposes WETH9-style `deposit`/`withdraw`
    // alongside owner-gated `mint`/`burn`, this same `WETHGateway` contract is what
    // runs on L2 — pointed at the Universal-WETH instead of the canonical WETH9. The
    // following tests lock in that invariant by pointing the gateway at a mock with
    // BOTH interfaces and asserting the bridge flow uses ONLY `deposit`/`withdraw`.
    // The owner-gated mint/burn surface is present (gateway is authorized minter) but
    // untouched — it exists only as an emergency valve, consistent with the governance
    // posture described in the contract NatSpec.
    // ====================================================================================

    function _switchToUniversalWETH() internal returns (MockUniversalWETH) {
        // Gateway is deployed as the owner/minter of the token. The production bootstrap
        // produces this via `UniversalTokenFactory.deployToken(gateway, L1_WETH, args)`
        // with `minter = pauser = gateway`; the mock captures that exact permission model.
        MockUniversalWETH universal = new MockUniversalWETH(address(wethGateway));
        vm.prank(admin);
        wethGateway.setWETH(address(universal));
        return universal;
    }

    function test_universalWETH_roundTrip_usesOnlyDepositWithdraw() public {
        MockUniversalWETH universal = _switchToUniversalWETH();

        // User "already holds" Universal-WETH on L2 via the public deposit path —
        // exactly how a real user would hold it (either from a previous bridge receive
        // or by depositing L2 ETH locally).
        uint256 amount = 2 ether;
        vm.deal(user, amount);
        vm.prank(user);
        universal.deposit{value: amount}();

        vm.prank(user);
        universal.approve(address(wethGateway), amount);

        // L2 → peer: unwrap via `withdraw`, forward ETH to the bridge.
        vm.prank(user);
        wethGateway.sendWETH(recipient, amount);
        assertEq(universal.balanceOf(user), 0);
        assertEq(address(bridge).balance, amount);

        // Peer → L2: bridge delivers, gateway wraps via `deposit`, forwards universal-WETH.
        bytes32 hash_ = _relayReceiveWETH(amount);
        assertEq(uint256(bridge.getReceivedMessage(hash_)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(universal.balanceOf(recipient), amount);

        // Normal bridge flow MUST NOT touch the owner-gated emergency surface. If a
        // future change routes supply through mint/burn it will show up here.
        assertEq(universal.mintCalls(), 0, "bridge flow must not call mint");
        assertEq(universal.burnCalls(), 0, "bridge flow must not call burn");
    }

    /// @dev The gateway is deployed as the Universal-WETH owner, so the owner-gated
    ///      mint / burn surface is available for governance — but only to the gateway's
    ///      owner-authorised paths, not to random callers. This verifies the emergency
    ///      valve is wired correctly and no user can bypass bridge accounting.
    function test_universalWETH_mintBurn_onlyGatewayCanCall() public {
        MockUniversalWETH universal = _switchToUniversalWETH();

        // Stranger cannot mint into the token.
        vm.prank(user);
        vm.expectRevert(MockUniversalWETH.OnlyOwner.selector);
        universal.mint(user, 1 ether);

        // Stranger cannot burn either.
        vm.prank(user);
        vm.expectRevert(MockUniversalWETH.OnlyOwner.selector);
        universal.burn(user, 1 ether);

        // The gateway (acting as owner) can. Simulating a future governance-triggered
        // emergency rescue where tokens must be minted out-of-band.
        vm.prank(address(wethGateway));
        universal.mint(recipient, 1 ether);
        assertEq(universal.balanceOf(recipient), 1 ether);
        assertEq(universal.mintCalls(), 1);

        vm.prank(address(wethGateway));
        universal.burn(recipient, 1 ether);
        assertEq(universal.balanceOf(recipient), 0);
        assertEq(universal.burnCalls(), 1);
    }
}
