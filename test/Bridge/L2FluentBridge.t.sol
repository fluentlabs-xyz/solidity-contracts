// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {FluentBridgeStorageLayout} from "../../contracts/bridge/FluentBridgeStorageLayout.sol";
import {IFluentBridge, IFluentBridgeEvents, IFluentBridgeErrors} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {IL2FluentBridge} from "../../contracts/interfaces/bridge/IL2FluentBridge.sol";
import {L1BlockOracle} from "../../contracts/oracles/L1BlockOracle.sol";
import {L1GasOracle} from "../../contracts/oracles/L1GasOracle.sol";
import {NoopReceiver} from "./Base.t.sol";

// ============ Test Base ============

abstract contract L2BridgeFeeBase is Test {
    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal relayer = makeAddr("relayer");
    address internal feeTreasury = makeAddr("feeTreasury");
    address internal user = makeAddr("user");
    /// @dev Must be a contract: {registerGateway} rejects EOAs.
    address internal recipient;

    L2FluentBridge internal bridge;
    L1BlockOracle internal blockOracle;
    L1GasOracle internal gasOracle;

    uint256 internal constant RECEIVE_DEADLINE = 100;

    uint256 internal constant OVERHEAD = 1 gwei; // per-gas overhead in wei
    uint256 internal constant SCALAR = 1e18; // 1x multiplier in WAD
    uint256 internal constant L1_GAS_PRICE = 30 gwei;
    uint256 internal constant L1_GAS_LIMIT = 100_000;

    function setUp() public virtual {
        recipient = address(new NoopReceiver());
        blockOracle = new L1BlockOracle(relayer);
        gasOracle = new L1GasOracle(relayer);

        vm.prank(relayer);
        blockOracle.updateL1BlockNumber(1);

        _deployBridge(OVERHEAD, SCALAR);

        vm.prank(relayer);
        gasOracle.updateL1GasPrice(L1_GAS_PRICE);
    }

    function _deployBridge(uint256 overhead, uint256 scalar) internal {
        IFluentBridge.InitConfiguration memory cfg = IFluentBridge.InitConfiguration({
            adminRole: admin,
            pauserRole: pauser,
            relayerRole: relayer,
            otherBridge: makeAddr("otherBridge")
        });

        L2FluentBridge impl = new L2FluentBridge();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                L2FluentBridge.initialize,
                (abi.encode(cfg), address(blockOracle), address(gasOracle), overhead, scalar, L1_GAS_LIMIT, feeTreasury)
            )
        );
        bridge = L2FluentBridge(payable(address(proxy)));

        // Send-side symmetry: all outbound tests here target `recipient`, and the bridge
        // now gates `sendMessage` against the gateway registry.
        vm.prank(admin);
        (bool ok, ) = address(bridge).call(abi.encodeWithSignature("registerGateway(address)", recipient));
        require(ok, "registerGateway failed in L2BridgeFeeBase setUp");
    }

    /// fee = L1GasLimit * ((l1GasPrice * scalar) / 1e18 + overhead)
    function _expectedFee() internal pure returns (uint256) {
        uint256 costPerUnit = (L1_GAS_PRICE * SCALAR) / 1e18 + OVERHEAD;
        return L1_GAS_LIMIT * costPerUnit;
    }

    function _decodeSentMessageValue(Vm.Log[] memory logs) internal pure returns (uint256 value) {
        // Signature mirrors {IFluentBridgeEvents-SentMessage}: the `fee` field was added between
        // `value` and `chainId`, so the layout is (value, fee, chainId, validUntilBlockNumber,
        // nonce, messageHash, data). Sender and to are indexed and live in topics[1..2].
        bytes32 sentMessageTopic = keccak256("SentMessage(address,address,uint256,uint256,uint256,uint256,uint256,bytes32,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sentMessageTopic) {
                (value, , , , , , ) = abi.decode(
                    logs[i].data,
                    (uint256, uint256, uint256, uint256, uint256, bytes32, bytes)
                );
                return value;
            }
        }
        revert("SentMessage event not found");
    }
}

// ============ getSentMessageFee Tests ============

contract GetSentMessageFeeTest is L2BridgeFeeBase {
    function test_getSentMessageFee_returnsCorrectFee() public view {
        assertEq(bridge.getSentMessageFee(), _expectedFee(), "fee mismatch");
    }

    function test_getSentMessageFee_zeroWhenConfigZero() public {
        vm.prank(admin);
        bridge.setGasPriceConfig(0, 0, 0);
        assertEq(bridge.getSentMessageFee(), 0, "fee should be zero when overhead and scalar are zero");
    }

    function test_getSentMessageFee_zeroWhenScalarAndOverheadZero() public {
        _deployBridge(0, 0);
        // _l1GasLimit is set in _deployBridge, but overhead=0, scalar=0 → _calculateGasCost=0 → fee=0
        assertEq(bridge.getSentMessageFee(), 0, "fee should be zero");
    }

    function test_getSentMessageFee_overheadOnlyWhenScalarZero() public {
        _deployBridge(2 gwei, 0);
        // _calculateGasCost = (l1GasPrice * 0) / 1e18 + 2 gwei = 2 gwei
        // fee = L1_GAS_LIMIT * 2 gwei
        uint256 expected = L1_GAS_LIMIT * 2 gwei;
        assertEq(bridge.getSentMessageFee(), expected, "fee should equal L1GasLimit * overhead");
    }

    function test_getSentMessageFee_updatesWhenGasPriceChanges() public {
        uint256 feeBefore = bridge.getSentMessageFee();

        vm.prank(relayer);
        gasOracle.updateL1GasPrice(60 gwei);

        uint256 feeAfter = bridge.getSentMessageFee();
        assertGt(feeAfter, feeBefore, "fee should increase with gas price");

        uint256 costPerUnit = (60 gwei * SCALAR) / 1e18 + OVERHEAD;
        assertEq(feeAfter, L1_GAS_LIMIT * costPerUnit, "fee formula mismatch after update");
    }

    function test_getSentMessageFee_updatesWhenConfigChanges() public {
        uint256 feeBefore = bridge.getSentMessageFee();

        vm.prank(admin);
        bridge.setGasPriceConfig(5 gwei, 2e18, L1_GAS_LIMIT); // 2x scalar, 5 gwei per-gas overhead

        uint256 feeAfter = bridge.getSentMessageFee();
        assertGt(feeAfter, feeBefore, "fee should increase with higher scalar");

        uint256 costPerUnit = (L1_GAS_PRICE * 2e18) / 1e18 + 5 gwei;
        assertEq(feeAfter, L1_GAS_LIMIT * costPerUnit, "fee formula mismatch after config update");
    }

    function test_getSentMessageFee_nonzeroWithDefaults() public view {
        assertGt(bridge.getSentMessageFee(), 0, "fee should be nonzero with default config");
    }
}

// ============ sendMessage Fee Deduction Tests ============

contract SendMessageFeeTest is L2BridgeFeeBase {
    function test_sendMessage_deductsFeeToTreasury() public {
        uint256 fee = bridge.getSentMessageFee();
        uint256 sendValue = 1 ether;
        uint256 totalRequired = sendValue + fee;

        uint256 treasuryBefore = feeTreasury.balance;

        vm.deal(user, totalRequired);
        vm.prank(user);
        bridge.sendMessage{value: totalRequired}(recipient, "");

        assertEq(feeTreasury.balance - treasuryBefore, fee, "treasury should receive exact fee");
    }

    function test_sendMessage_bridgeRetainsValueMinusFee() public {
        uint256 fee = bridge.getSentMessageFee();
        uint256 totalSent = 1 ether;

        uint256 bridgeBefore = address(bridge).balance;

        vm.deal(user, totalSent);
        vm.prank(user);
        bridge.sendMessage{value: totalSent}(recipient, "");

        uint256 bridgeRetained = address(bridge).balance - bridgeBefore;
        assertEq(bridgeRetained, totalSent - fee, "bridge should retain msg.value minus fee");
    }

    function test_sendMessage_eventValueIncludesFee() public {
        // Post-fee-split semantics: `SentMessage.value` is the gross msg.value (cross-chain
        // value + fee), and `SentMessage.fee` is emitted as a separate field. Consumers that
        // need the cross-chain value compute `value - fee`. See {IFluentBridgeEvents-SentMessage}.
        uint256 fee = bridge.getSentMessageFee();
        uint256 totalSent = 1 ether;

        vm.deal(user, totalSent);
        vm.recordLogs();
        vm.prank(user);
        bridge.sendMessage{value: totalSent}(recipient, "");

        uint256 emittedValue = _decodeSentMessageValue(vm.getRecordedLogs());
        assertEq(emittedValue, totalSent, "event value should equal msg.value (fee inclusive)");
        assertEq(emittedValue - fee, totalSent - fee, "cross-chain value derives as value - fee");
    }

    function test_RevertIf_sendMessage_insufficientValueForFee() public {
        uint256 fee = bridge.getSentMessageFee();
        assertGt(fee, 0, "fee must be nonzero for this test");

        vm.deal(user, fee - 1);
        vm.prank(user);
        vm.expectRevert(); // arithmetic underflow: msg.value - fee
        bridge.sendMessage{value: fee - 1}(recipient, "");
    }

    function test_sendMessage_zeroFeeNoTreasuryTransfer() public {
        vm.prank(admin);
        bridge.setGasPriceConfig(0, 0, 0);
        assertEq(bridge.getSentMessageFee(), 0, "fee should be zero");

        uint256 treasuryBefore = feeTreasury.balance;

        vm.deal(user, 1 ether);
        vm.prank(user);
        bridge.sendMessage{value: 1 ether}(recipient, "");

        assertEq(feeTreasury.balance, treasuryBefore, "treasury should not receive anything when fee is zero");
    }

    function test_sendMessage_exactFeeResultsInZeroCrossChainValue() public {
        uint256 fee = bridge.getSentMessageFee();
        assertGt(fee, 0, "fee must be nonzero for this test");

        vm.deal(user, fee);
        vm.recordLogs();
        vm.prank(user);
        bridge.sendMessage{value: fee}(recipient, "");

        // Post-fee-split semantics: emitted `value` is the gross msg.value, so when the user
        // sends exactly the fee the gross value equals the fee and the derived cross-chain
        // value (`value - fee`) is zero.
        uint256 emittedValue = _decodeSentMessageValue(vm.getRecordedLogs());
        assertEq(emittedValue, fee, "emitted value should equal fee when only fee is sent");
        assertEq(emittedValue - fee, 0, "cross-chain value should be zero when only fee is sent");
    }

    function testFuzz_sendMessage_feeDeductedCorrectly(uint96 rawGasPrice) public {
        uint256 gasPrice = bound(uint256(rawGasPrice), 1 gwei, 500 gwei);

        vm.prank(relayer);
        gasOracle.updateL1GasPrice(gasPrice);

        uint256 fee = bridge.getSentMessageFee();
        uint256 totalSent = fee + 0.5 ether;

        uint256 treasuryBefore = feeTreasury.balance;

        vm.deal(user, totalSent);
        vm.prank(user);
        bridge.sendMessage{value: totalSent}(recipient, "");

        assertEq(feeTreasury.balance - treasuryBefore, fee, "treasury receives exact fee");
    }
}

// ============ Gas Price Config Admin Tests ============

contract GasPriceConfigTest is L2BridgeFeeBase {
    function test_setGasPriceConfig_updatesAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit IL2FluentBridge.GasPriceConfigUpdated(OVERHEAD, 5 gwei, SCALAR, 2e18, L1_GAS_LIMIT, L1_GAS_LIMIT);

        vm.prank(admin);
        bridge.setGasPriceConfig(5 gwei, 2e18, L1_GAS_LIMIT);

        L2FluentBridge.GasPriceConfig memory cfg = bridge.getGasPriceConfig();
        assertEq(cfg._overheadGasPrice, 5 gwei, "overhead mismatch");
        assertEq(cfg._scalarGasPrice, 2e18, "scalar mismatch");
    }

    function test_RevertIf_setGasPriceConfig_callerNotAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        bridge.setGasPriceConfig(0, 0, 0);
    }

    function test_setGasPriceConfig_zeroValuesAllowed() public {
        vm.prank(admin);
        bridge.setGasPriceConfig(0, 0, 0);

        assertEq(bridge.getSentMessageFee(), 0, "fee should be zero");
    }

    function test_setL1GasPriceOracle_updatesAndEmits() public {
        address newOracle = makeAddr("newGasOracle");

        vm.expectEmit(true, true, false, false);
        emit IL2FluentBridge.L1GasPriceOracleUpdated(address(gasOracle), newOracle);

        vm.prank(admin);
        bridge.setL1GasPriceOracle(newOracle);

        assertEq(bridge.getL1GasPriceOracle(), newOracle, "oracle address mismatch");
    }

    function test_RevertIf_setL1GasPriceOracle_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert();
        bridge.setL1GasPriceOracle(address(0));
    }

    function test_RevertIf_setL1GasPriceOracle_callerNotAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        bridge.setL1GasPriceOracle(makeAddr("oracle"));
    }
}

// ============ Fee Treasury Tests ============

contract FeeTreasuryTest is L2BridgeFeeBase {
    function test_getFeeTreasury_returnsConfigured() public view {
        assertEq(bridge.getFeeTreasury(), feeTreasury, "treasury mismatch");
    }

    function test_setFeeTreasury_updatesAndEmits() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectEmit(true, true, false, false);
        emit IFluentBridgeEvents.FeeTreasuryUpdated(feeTreasury, newTreasury);

        vm.prank(admin);
        bridge.setFeeTreasury(newTreasury);

        assertEq(bridge.getFeeTreasury(), newTreasury, "treasury not updated");
    }

    function test_RevertIf_setFeeTreasury_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert();
        bridge.setFeeTreasury(address(0));
    }

    function test_RevertIf_setFeeTreasury_callerNotAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        bridge.setFeeTreasury(makeAddr("newTreasury"));
    }

    function test_sendMessage_feeGoesToUpdatedTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(admin);
        bridge.setFeeTreasury(newTreasury);

        uint256 fee = bridge.getSentMessageFee();
        uint256 totalSent = fee + 0.1 ether;

        vm.deal(user, totalSent);
        vm.prank(user);
        bridge.sendMessage{value: totalSent}(recipient, "");

        assertEq(newTreasury.balance, fee, "new treasury should receive fee");
        assertEq(feeTreasury.balance, 0, "old treasury should receive nothing");
    }
}

// ============ Receive Message (no fee on inbound) ============

contract ReceiveMessageNoFeeTest is L2BridgeFeeBase {
    function test_receiveMessage_noFeeChargedOnInbound() public {
        uint256 treasuryBefore = feeTreasury.balance;
        uint256 amount = 0.5 ether;

        address otherBridge = makeAddr("otherBridge");

        // `recipient` is already registered in L2BridgeFeeBase.setUp().

        vm.deal(address(bridge), amount);
        vm.prank(relayer);
        // validUntilBlockNumber well beyond the L1 block oracle value so the committed expiry is not reached
        bridge.receiveMessage(otherBridge, recipient, amount, block.chainid + 1, type(uint64).max, 0, "");

        assertEq(feeTreasury.balance, treasuryBefore, "treasury should not receive anything on inbound");
        assertEq(recipient.balance, amount, "recipient should receive full amount");
    }

    /// @dev Relayer-delivered receive with an unregistered `to` must revert up-front.
    ///      Confirms the gateway-registry guard also fires on the L2 receive path (base
    ///      `FluentBridge._receiveMessage`), not only on the L1 proof path.
    function test_RevertIf_receiveMessage_gatewayNotRegistered() public {
        address otherBridge = makeAddr("otherBridge");
        address unregistered = makeAddr("unregistered-destination");

        vm.deal(address(bridge), 1 ether);
        vm.prank(relayer);
        vm.expectRevert(IFluentBridgeErrors.GatewayNotWhitelisted.selector);
        bridge.receiveMessage(otherBridge, unregistered, 1 ether, block.chainid + 1, type(uint64).max, 0, "");
    }

    /// @dev Symmetric send-side admission on L2: `sendMessage` to a non-registered
    ///      destination reverts before fee collection, so user funds never leave the
    ///      wallet when the admin hasn't whitelisted the remote counterpart.
    function test_RevertIf_sendMessage_gatewayNotRegistered() public {
        address unregistered = makeAddr("unregistered-destination");
        uint256 fee = bridge.getSentMessageFee();
        vm.deal(user, fee + 1 ether);
        vm.prank(user);
        vm.expectRevert(IFluentBridgeErrors.GatewayNotWhitelisted.selector);
        bridge.sendMessage{value: fee + 1 ether}(unregistered, hex"00");
    }
}

// ============ L2 Branch Coverage Tests ============

contract RejectEther {
    receive() external payable {
        revert("reject-eth");
    }
}

contract L2FluentBridgeTest is L2BridgeFeeBase {
    /// @dev Mirror of {FluentBridgeStorageLayout-FLUENT_BRIDGE_STORAGE_LOCATION}, i.e.
    ///      keccak256(abi.encode(uint256(keccak256("Fluent.storage.FluentBridgeStorage")) - 1)) & ~bytes32(uint256(0xff)).
    ///      MUST stay in sync with the contract constant; the test directly pokes
    ///      `_feeTreasury` at this slot to drive the zero-treasury revert branch.
    bytes32 internal constant FLUENT_BRIDGE_STORAGE_LOCATION = 0x1d32f057e9fce0670715dab7ddeb05958b1ba8f4bd87a5dcabc7ec5913505500;

    function test_RevertIf_chargeSendFee_zeroFeeTreasury() public {
        // Directly zero out the _feeTreasury storage slot (slot offset 6 in the struct)
        bytes32 treasurySlot = bytes32(uint256(FLUENT_BRIDGE_STORAGE_LOCATION) + 6);
        vm.store(address(bridge), treasurySlot, bytes32(0));
        assertEq(bridge.getFeeTreasury(), address(0), "treasury should be zero");

        uint256 fee = bridge.getSentMessageFee();
        assertGt(fee, 0, "fee must be nonzero to trigger the branch");

        vm.deal(user, fee + 1 ether);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IFluentBridgeErrors.ZeroAddressNotAllowed.selector, "feeTreasury"));
        bridge.sendMessage{value: fee + 1 ether}(recipient, "");
    }

    function test_RevertIf_chargeSendFee_treasuryRejectsEth() public {
        RejectEther rejector = new RejectEther();
        vm.prank(admin);
        bridge.setFeeTreasury(address(rejector));

        uint256 fee = bridge.getSentMessageFee();
        assertGt(fee, 0, "fee must be nonzero to trigger the branch");

        vm.deal(user, fee + 1 ether);
        vm.prank(user);
        vm.expectRevert(IL2FluentBridge.FailedToDeductFee.selector);
        bridge.sendMessage{value: fee + 1 ether}(recipient, "");
    }

    function test_RevertIf_beforeReceiveMessage_zeroValidUntilBlockNumber() public {
        address otherBridge = makeAddr("otherBridge");
        vm.deal(address(bridge), 1 ether);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IFluentBridgeErrors.ZeroValueNotAllowed.selector, "validUntilBlockNumber"));
        bridge.receiveMessage(otherBridge, recipient, 0, block.chainid + 1, 0, 0, "");
    }

    function test_RevertIf_setL1GasPriceOracle_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IFluentBridgeErrors.ZeroAddressNotAllowed.selector, "l1GasPriceOracle"));
        bridge.setL1GasPriceOracle(address(0));
    }
}
