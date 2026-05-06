// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vm} from "forge-std/Vm.sol";

import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";
import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {IGatewayBaseErrors, IGatewayBaseEvents} from "../../contracts/interfaces/gateways/IGatewayBase.sol";
import {IERC20GatewayErrors} from "../../contracts/interfaces/gateways/IERC20Gateway.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {MockERC20Token} from "../../test/mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "../../test/mocks/MockFeeOnTransferERC20.sol";
import {MockMutableMetadataERC20} from "../../test/mocks/MockMutableMetadataERC20.sol";
import {IFluentBridgeEvents} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {GatewayBase} from "./Base.t.sol";

contract ERC20GatewayTest is GatewayBase {
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

    function test_setBridgingExcludedOrigin_zeroOrigin_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IGatewayBaseErrors.ZeroAddressNotAllowed.selector, "originToken"));
        gateway.setBridgingExcludedOrigin(address(0), true);
    }

    function test_sendTokens_originPath_revertsWhenBridgingExcluded() public {
        vm.prank(admin);
        gateway.setBridgingExcludedOrigin(address(originToken), true);

        vm.prank(user);
        originToken.approve(address(gateway), 1 ether);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IERC20GatewayErrors.BridgingExcludedOriginToken.selector, address(originToken)));
        gateway.sendTokens(address(originToken), recipient, 1 ether);
    }

    function test_receivePeggedTokens_revertsWhenBridgingExcluded() public {
        vm.prank(admin);
        gateway.setBridgingExcludedOrigin(address(originToken), true);

        address predictedPegged = _predictedPegged();
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock Token", uint8(18));
        bytes memory message = abi.encodeCall(
            ERC20Gateway.receivePeggedTokens,
            (address(originToken), predictedPegged, user, recipient, 1 ether, tokenMetadata)
        );

        vm.expectRevert(abi.encodeWithSelector(IERC20GatewayErrors.BridgingExcludedOriginToken.selector, address(originToken)));
        _relayMessage(remoteGateway, address(gateway), 0, message);
    }

    function test_sendTokens_peggedPath_revertsWhenBridgingExcluded() public {
        address predictedPegged = _predictedPegged();
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock Token", uint8(18));
        bytes memory message = abi.encodeCall(
            ERC20Gateway.receivePeggedTokens,
            (address(originToken), predictedPegged, user, user, 10 ether, tokenMetadata)
        );
        _relayMessage(remoteGateway, address(gateway), 0, message);

        vm.prank(admin);
        gateway.setBridgingExcludedOrigin(address(originToken), true);

        ERC20PeggedToken pegged = ERC20PeggedToken(predictedPegged);
        vm.prank(user);
        pegged.approve(address(gateway), 1 ether);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IERC20GatewayErrors.BridgingExcludedOriginToken.selector, address(originToken)));
        gateway.sendTokens(predictedPegged, recipient, 1 ether);
    }

    function test_setBridgingExcludedOrigin_clearAllowsBridgingAgain() public {
        vm.prank(admin);
        gateway.setBridgingExcludedOrigin(address(originToken), true);
        assertTrue(gateway.isBridgingExcludedOrigin(address(originToken)));

        vm.prank(admin);
        gateway.setBridgingExcludedOrigin(address(originToken), false);
        assertFalse(gateway.isBridgingExcludedOrigin(address(originToken)));

        uint256 amount = 1 ether;
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

    /// @dev With whitelist enabled and the originating batch Preconfirmed, a token NOT
    ///      registered on the FastWithdrawalList must be rejected — forcing the user to wait
    ///      for finalization before withdrawing this token.
    function test_receivePeggedTokens_marksFailedWhenPreconfirmedAndTokenNotInFastList() public {
        vm.prank(admin);
        gateway.setWhitelistEnabled(true);
        // Simulate the optimistic window so the gate fires.
        _mockBridgePreconfirmed(true);

        address predictedPegged = _predictedPegged();
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock Token", uint8(18));
        bytes memory message = abi.encodeCall(
            ERC20Gateway.receivePeggedTokens,
            (address(originToken), predictedPegged, user, recipient, 1 ether, tokenMetadata)
        );

        (bytes32 messageHash, , ) = _relayMessage(remoteGateway, address(gateway), 0, message);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));

        // Bucket is unregistered, so usage stays at zero.
        (, uint256 hourlyUsed, , uint256 dailyUsed) = fastWithdrawalList.getUsage(address(originToken));
        assertEq(hourlyUsed, 0);
        assertEq(dailyUsed, 0);
    }

    /// @dev When the whitelist is enabled but the batch is FINALIZED (i.e. not Preconfirmed),
    ///      no rate limits apply even for an unregistered token. This is the "Finalized →
    ///      unrestricted" branch of the optimistic-withdrawal policy.
    function test_receivePeggedTokens_finalizedBatchSkipsLimitsForUnregisteredToken() public {
        vm.prank(admin);
        gateway.setWhitelistEnabled(true);
        // No mock — bridge defaults to "not preconfirmed", which the gateway treats as Finalized.

        address predictedPegged = _predictedPegged();
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock Token", uint8(18));
        bytes memory message = abi.encodeCall(
            ERC20Gateway.receivePeggedTokens,
            (address(originToken), predictedPegged, user, recipient, 100 ether, tokenMetadata)
        );

        (bytes32 messageHash, , ) = _relayMessage(remoteGateway, address(gateway), 0, message);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
    }

    function test_receivePeggedTokens_enforcesFastWithdrawalLimits() public {
        vm.prank(admin);
        fastWithdrawalList.registerToken(address(originToken), 3 ether, 5 ether);
        vm.prank(admin);
        gateway.setWhitelistEnabled(true);
        _mockBridgePreconfirmed(true);

        address predictedPegged = _predictedPegged();
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock Token", uint8(18));

        // Within-limit receive of 2 ether succeeds and consumes the hourly/daily counters.
        bytes memory okMsg = abi.encodeCall(
            ERC20Gateway.receivePeggedTokens,
            (address(originToken), predictedPegged, user, recipient, 2 ether, tokenMetadata)
        );
        (bytes32 okHash, , ) = _relayMessage(remoteGateway, address(gateway), 0, okMsg);
        assertEq(uint256(bridge.getReceivedMessage(okHash)), uint256(IFluentBridge.MessageStatus.Success));

        (uint256 currentHourWindow, uint256 hourlyUsed, uint256 currentDayWindow, uint256 dailyUsed) = fastWithdrawalList.getUsage(
            address(originToken)
        );
        assertEq(currentHourWindow, block.timestamp / 1 hours);
        assertEq(hourlyUsed, 2 ether);
        assertEq(currentDayWindow, block.timestamp / 1 days);
        assertEq(dailyUsed, 2 ether);

        // Over-hourly-limit receive (2 + 2 > 3) must fail; counters must not advance.
        bytes memory overHourly = abi.encodeCall(
            ERC20Gateway.receivePeggedTokens,
            (address(originToken), predictedPegged, user, recipient, 2 ether, tokenMetadata)
        );
        (bytes32 overHourlyHash, , ) = _relayMessage(remoteGateway, address(gateway), 0, overHourly);
        assertEq(uint256(bridge.getReceivedMessage(overHourlyHash)), uint256(IFluentBridge.MessageStatus.Failed));

        (, hourlyUsed, , dailyUsed) = fastWithdrawalList.getUsage(address(originToken));
        assertEq(hourlyUsed, 2 ether);
        assertEq(dailyUsed, 2 ether);

        // Next hour, hourly window resets; daily continues to accumulate.
        vm.warp(block.timestamp + 1 hours);
        bytes memory nextHour = abi.encodeCall(
            ERC20Gateway.receivePeggedTokens,
            (address(originToken), predictedPegged, user, recipient, 2 ether, tokenMetadata)
        );
        (bytes32 nextHash, , ) = _relayMessage(remoteGateway, address(gateway), 0, nextHour);
        assertEq(uint256(bridge.getReceivedMessage(nextHash)), uint256(IFluentBridge.MessageStatus.Success));

        (, hourlyUsed, , dailyUsed) = fastWithdrawalList.getUsage(address(originToken));
        assertEq(hourlyUsed, 2 ether);
        assertEq(dailyUsed, 4 ether);

        // Disable hourly, keep daily at 5. Next receive of 2 would push daily to 6 → fail.
        vm.prank(admin);
        fastWithdrawalList.setLimit(address(originToken), 0, 5 ether);

        bytes memory overDaily = abi.encodeCall(
            ERC20Gateway.receivePeggedTokens,
            (address(originToken), predictedPegged, user, recipient, 2 ether, tokenMetadata)
        );
        (bytes32 overDailyHash, , ) = _relayMessage(remoteGateway, address(gateway), 0, overDaily);
        assertEq(uint256(bridge.getReceivedMessage(overDailyHash)), uint256(IFluentBridge.MessageStatus.Failed));

        (, hourlyUsed, , dailyUsed) = fastWithdrawalList.getUsage(address(originToken));
        assertEq(hourlyUsed, 2 ether);
        assertEq(dailyUsed, 4 ether);
    }

    function test_receiveOriginTokens_withZeroRecipient_marksFailed() public {
        bytes memory message = abi.encodeCall(ERC20Gateway.receiveOriginTokens, (address(originToken), user, address(0), 1 ether));
        (bytes32 messageHash, , ) = _relayMessage(remoteGateway, address(gateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_sendTokens_revertsForZeroRecipient() public {
        vm.prank(user);
        vm.expectRevert(IGatewayBaseErrors.InvalidRecipient.selector);
        gateway.sendTokens(address(originToken), address(0), 1 ether);
    }

    function test_receivePeggedTokens_directCall_revertsOnlyFluentBridge() public {
        address predictedPegged = _predictedPegged();
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock Token", uint8(18));

        vm.prank(user);
        vm.expectRevert(IGatewayBaseErrors.OnlyFluentBridge.selector);
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

    function test_setOtherSide_universal_setsAllFields() public {
        address remoteFactory = makeAddr("remote-universal-factory");
        address remoteImplementation = makeAddr("remote-implementation");

        vm.prank(admin);
        gateway.setOtherSide(true, remoteGateway, sourceChainId, remoteImplementation, remoteFactory, address(0));

        assertEq(gateway.getOtherSideBeacon(), address(0));
        assertEq(gateway.getOtherSideChainId(), sourceChainId);
        assertEq(gateway.getOtherSideFactory(), remoteFactory);
        assertEq(gateway.getOtherSideTokenImplementation(), remoteImplementation);
    }

    function test_computeOtherSidePeggedTokenAddress_withUniversalConfig() public {
        address remoteFactory = makeAddr("remote-universal-factory");
        address remoteImplementation = makeAddr("remote-implementation");

        vm.prank(admin);
        gateway.setOtherSide(true, remoteGateway, sourceChainId, remoteImplementation, remoteFactory, address(0));

        address computed = gateway.computeOtherSidePeggedTokenAddress(remoteGateway, address(originToken));
        assertTrue(computed != address(0));
    }

    function test_setOtherSide_revertsOnZeroRemoteGateway() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGatewayBaseErrors.ZeroAddressNotAllowed.selector,
                "otherSideGateway or otherSideTokenImplementation or otherSideFactory"
            )
        );
        gateway.setOtherSide(true, address(0), sourceChainId, makeAddr("impl"), makeAddr("factory"), address(0));
    }

    /// @dev Success path for `receiveOriginTokens`: gateway must hold the origin ERC20 before transfer out.
    function test_receiveOriginTokens_viaBridge_releasesEscrowedOrigin() public {
        uint256 amount = 3 ether;
        vm.prank(user);
        require(originToken.transfer(address(gateway), amount), "originToken transfer failed");

        bytes memory message = abi.encodeCall(ERC20Gateway.receiveOriginTokens, (address(originToken), user, recipient, amount));
        (bytes32 messageHash, , ) = _relayMessage(remoteGateway, address(gateway), 0, message);

        assertEq(originToken.balanceOf(recipient), amount);
        assertEq(originToken.balanceOf(address(gateway)), 0);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
    }

    /// @dev `_sendOriginTokens` when remote is universal (chain id set, beacon cleared).
    function test_sendTokens_originPath_escrows_withUniversalOtherSideConfig() public {
        address remoteFactory = makeAddr("remote-universal-factory");
        address remoteImplementation = makeAddr("remote-implementation");

        vm.prank(admin);
        gateway.setOtherSide(true, remoteGateway, sourceChainId, remoteImplementation, remoteFactory, address(0));

        uint256 amount = 2 ether;
        vm.prank(user);
        originToken.approve(address(gateway), amount);
        vm.prank(user);
        gateway.sendTokens(address(originToken), recipient, amount);

        assertEq(originToken.balanceOf(address(gateway)), amount);
    }

    function test_sendTokens_revertsWhenOtherSideGatewayUnset() public {
        ERC20Gateway impl = new ERC20Gateway();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(ERC20Gateway.initialize, (admin, address(bridge), address(factory)))
        );
        ERC20Gateway gw = ERC20Gateway(payable(address(proxy)));

        vm.prank(admin);
        factory.setPaymentGateway(address(gw));

        vm.prank(user);
        originToken.approve(address(gw), 1 ether);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IGatewayBaseErrors.ZeroAddressNotAllowed.selector, "getOtherSideGateway"));
        gw.sendTokens(address(originToken), recipient, 1 ether);
    }

    function test_setTokenFactory_updatesAndEmits() public {
        ERC20TokenFactory newFactoryImpl = new ERC20TokenFactory();
        ERC1967Proxy newFactoryProxy = new ERC1967Proxy(
            address(newFactoryImpl),
            abi.encodeCall(ERC20TokenFactory.initialize, (admin, address(peggedImplementation)))
        );
        address newFactory = address(newFactoryProxy);

        vm.expectEmit(true, true, false, false, address(gateway));
        emit IGatewayBaseEvents.TokenFactoryUpdated(address(factory), newFactory);
        vm.prank(admin);
        gateway.setTokenFactory(newFactory);
        assertEq(gateway.getTokenFactory(), newFactory);
    }

    function test_setTokenFactory_revertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IGatewayBaseErrors.ZeroAddressNotAllowed.selector, "tokenFactory"));
        gateway.setTokenFactory(address(0));
    }

    function test_setOtherSideTokenImplementation_updatesAndEmits() public {
        address newImpl = makeAddr("fresh-pegged-impl");

        vm.expectEmit(true, true, false, false, address(gateway));
        emit IGatewayBaseEvents.OtherSideTokenImplementationUpdated(address(peggedImplementation), newImpl);
        vm.prank(admin);
        gateway.setOtherSideTokenImplementation(newImpl);
        assertEq(gateway.getOtherSideTokenImplementation(), newImpl);
    }

    function test_setOtherSideTokenImplementation_revertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IGatewayBaseErrors.ZeroAddressNotAllowed.selector, "otherSideTokenImplementation"));
        gateway.setOtherSideTokenImplementation(address(0));
    }

    function test_setOtherSideChainId_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(gateway));
        emit IGatewayBaseEvents.OtherSideChainIdUpdated(0, 4242);
        vm.prank(admin);
        gateway.setOtherSideChainId(4242);
        assertEq(gateway.getOtherSideChainId(), 4242);
    }

    function test_setOtherSideChainId_revertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IGatewayBaseErrors.ZeroValueNotAllowed.selector, "newOtherSideChainId"));
        gateway.setOtherSideChainId(0);
    }

    function test_receivePeggedTokens_withZeroRecipient_marksFailed() public {
        address predictedPegged = _predictedPegged();
        bytes memory tokenMetadata = abi.encode("MOCK", "Mock Token", uint8(18));
        bytes memory message = abi.encodeCall(
            ERC20Gateway.receivePeggedTokens,
            (address(originToken), predictedPegged, user, address(0), 1 ether, tokenMetadata)
        );

        (bytes32 messageHash, , ) = _relayMessage(remoteGateway, address(gateway), 0, message);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_RevertIf_setBridgeContract_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IGatewayBaseErrors.ZeroAddressNotAllowed.selector, "newBridgeContract"));
        gateway.setBridgeContract(address(0));
    }

    function test_computeTokenAddress_matchesPredictedHelper() public view {
        address predicted = gateway.computeTokenAddress(address(gateway), address(originToken));
        assertEq(predicted, _predictedPegged(), "computeTokenAddress mismatch vs helper");
    }

    // ============ Origin metadata drift ============

    /// @dev With a Universal-token destination, CREATE2 for the remote pegged address depends on
    ///      `(name, symbol, decimals)`. The gateway caches the first-computed remote address per
    ///      origin token and reuses it on every subsequent send — so mutating `name` / `symbol`
    ///      on the origin ERC20 after the first send must NOT change the address carried in the
    ///      outbound bridge message (which would otherwise make the remote `receivePeggedTokens`
    ///      deploy at a new CREATE2 address and revert with {WrongPeggedToken}).
    function test_sendTokens_originPath_cachedAddressStableAfterSymbolChange() public {
        // Switch to Universal remote config so the address is sensitive to metadata.
        address remoteFactory = makeAddr("remote-universal-factory");
        address remoteImplementation = makeAddr("remote-implementation");
        vm.prank(admin);
        gateway.setOtherSide(true, remoteGateway, sourceChainId, remoteImplementation, remoteFactory, address(0));

        // Deploy an origin token with mutable metadata and fund the user.
        MockMutableMetadataERC20 mut = new MockMutableMetadataERC20("Mutable One", "MUT1", 1_000 ether, user);

        // Snapshot what the address should be under the V1 (pre-send) metadata.
        address addrBeforeSend = gateway.computeOtherSidePeggedTokenAddress(remoteGateway, address(mut));
        assertTrue(addrBeforeSend != address(0), "address should be predictable");

        // First send populates the cache.
        vm.prank(user);
        mut.approve(address(gateway), 2 ether);
        vm.prank(user);
        gateway.sendTokens(address(mut), recipient, 1 ether);

        // Now mutate the origin's symbol + name and verify what CREATE2 would produce now
        // is DIFFERENT from the cached value — otherwise the test is vacuous.
        mut.setMetadata("Mutable Two", "MUT2");
        assertEq(mut.symbol(), "MUT2", "symbol should have changed");

        // View must still return the cached address (the short-circuit branch), not a fresh
        // CREATE2 derived from the new symbol.
        address addrAfterDrift = gateway.computeOtherSidePeggedTokenAddress(remoteGateway, address(mut));
        assertEq(addrAfterDrift, addrBeforeSend, "view should return cached address after drift");

        // Second send: capture `SentMessage` and verify the pegged address encoded in the
        // cross-chain payload is the cached one, not something derived from the new symbol.
        vm.recordLogs();
        vm.prank(user);
        gateway.sendTokens(address(mut), recipient, 1 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        address sentPegged = _peggedFromSentMessage(logs);
        assertEq(sentPegged, addrBeforeSend, "bridge payload must carry the cached pegged address");
    }

    /// @dev Decode the pegged-token address from the most recent `SentMessage` event carrying a
    ///      `receivePeggedTokens(address,address,address,address,uint256,bytes)` call.
    function _peggedFromSentMessage(Vm.Log[] memory logs) internal pure returns (address) {
        bytes32 topic = IFluentBridgeEvents.SentMessage.selector;
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory log = logs[i - 1];
            if (log.topics.length > 0 && log.topics[0] == topic) {
                // `data` = abi.encode(value, fee, chainId, validUntilBlockNumber, nonce, messageHash, data(bytes)).
                (, , , , , , bytes memory message) = abi.decode(
                    log.data,
                    (uint256, uint256, uint256, uint256, uint256, bytes32, bytes)
                );
                // Strip the 4-byte selector and decode `(originToken, peggedToken, from, to, amount, tokenMetadata)`.
                bytes memory args = new bytes(message.length - 4);
                for (uint256 j = 0; j < args.length; j++) {
                    args[j] = message[j + 4];
                }
                (, address peggedToken, , , , ) = abi.decode(args, (address, address, address, address, uint256, bytes));
                return peggedToken;
            }
        }
        revert("no SentMessage in logs");
    }

    // ============ Fee-on-transfer ============

    /// @dev Verifies that the gateway escrows the actual received amount (after fee)
    ///      and encodes that amount in the bridge message, not the requested amount.
    function test_sendTokens_originPath_feeOnTransfer_escrewsActualAmount() public {
        // Deploy a 2% fee-on-transfer token and give 1000 to user
        uint256 feeBps = 200;
        MockFeeOnTransferERC20 fotToken = new MockFeeOnTransferERC20("FeeToken", "FOT", 1_000 ether, user, feeBps);

        // Configure the gateway to know about the other side so _sendOriginTokens passes validation
        // (otherSideGateway and otherSideFactory are already set by _deployGatewayStack)

        uint256 sendAmount = 100 ether;
        uint256 expectedFee = (sendAmount * feeBps) / 10_000; // 2 ether
        uint256 expectedReceived = sendAmount - expectedFee; // 98 ether

        vm.prank(user);
        fotToken.approve(address(gateway), sendAmount);

        // Record gateway balance before
        uint256 gatewayBalBefore = fotToken.balanceOf(address(gateway));

        // Send tokens through the gateway
        vm.prank(user);
        gateway.sendTokens(address(fotToken), recipient, sendAmount);

        // Gateway should hold exactly the post-fee amount
        uint256 gatewayBalAfter = fotToken.balanceOf(address(gateway));
        assertEq(gatewayBalAfter - gatewayBalBefore, expectedReceived, "gateway should escrow actual received amount, not requested amount");
    }
}
