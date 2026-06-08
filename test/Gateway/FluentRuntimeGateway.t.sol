// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vm} from "forge-std/Vm.sol";

import {IFluentBridge, IFluentBridgeErrors} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {IGatewayBaseErrors} from "../../contracts/interfaces/gateways/IGatewayBase.sol";
import {
    IFluentRuntimeGateway,
    IFluentRuntimeGatewayErrors,
    IFluentRuntimeResponseHandler
} from "../../contracts/interfaces/gateways/IFluentRuntimeGateway.sol";
import {FluentRuntimeGateway} from "../../contracts/gateways/FluentRuntimeGateway.sol";
import {GatewayBase} from "./Base.t.sol";
import {MockERC20Token} from "../mocks/MockERC20.sol";

contract NativeWasmDeployTarget {
    uint256 public immutable initialValue;

    constructor(uint256 initialValue_) payable {
        initialValue = initialValue_;
    }
}

contract NativeWasmInvokeTarget {
    uint256 public lastValue;
    bytes public lastPayload;

    function run(bytes calldata payload) external payable returns (uint256) {
        lastValue = msg.value;
        lastPayload = payload;
        return 123;
    }

    function fail() external pure {
        revert("RUNTIME_REVERT");
    }
}

contract RecordingFluentRuntimeResponseHandler is IFluentRuntimeResponseHandler {
    bytes32 public lastRequestId;
    address public lastRequester;
    bool public lastSuccess;
    bytes public lastReturnData;

    function handleFluentRuntimeResult(bytes32 requestId, address requester, bool success, bytes calldata returnData)
        external
    {
        lastRequestId = requestId;
        lastRequester = requester;
        lastSuccess = success;
        lastReturnData = returnData;
    }
}

contract ReenteringWasmInvokeTarget {
    IFluentRuntimeGateway internal immutable gateway;
    bytes4 public caughtSelector;

    constructor(IFluentRuntimeGateway gateway_) {
        gateway = gateway_;
    }

    function run() external payable returns (bytes4) {
        try gateway.requestDeploy(hex"00", "") returns (bytes32) {
            caughtSelector = bytes4(0);
        } catch (bytes memory reason) {
            caughtSelector = _selector(reason);
        }
        return caughtSelector;
    }

    function _selector(bytes memory reason) private pure returns (bytes4 selector) {
        if (reason.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(reason, 0x20))
            }
        }
    }
}

contract ReenteringFluentRuntimeResponseHandler is IFluentRuntimeResponseHandler {
    IFluentRuntimeGateway internal immutable gateway;
    bytes4 public caughtSelector;

    constructor(IFluentRuntimeGateway gateway_) {
        gateway = gateway_;
    }

    function handleFluentRuntimeResult(bytes32, address, bool, bytes calldata) external {
        try gateway.requestDeploy(hex"00", "") returns (bytes32) {
            caughtSelector = bytes4(0);
        } catch (bytes memory reason) {
            caughtSelector = _selector(reason);
        }
    }

    function _selector(bytes memory reason) private pure returns (bytes4 selector) {
        if (reason.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(reason, 0x20))
            }
        }
    }
}

contract FluentRuntimeGatewayTest is GatewayBase {
    bytes4 private constant REENTRANCY_GUARD_REENTRANT_CALL = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    FluentRuntimeGateway internal fluentRuntimeGateway;
    MockERC20Token internal blend;
    address internal feeRecipient = makeAddr("feeRecipient");

    function setUp() public override {
        super.setUp();
        _deployBridge(0);
        _deployFluentRuntimeGateway();
    }

    function _deployFluentRuntimeGateway() internal {
        FluentRuntimeGateway impl = new FluentRuntimeGateway();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(FluentRuntimeGateway.initialize, (admin, address(bridge))));
        fluentRuntimeGateway = FluentRuntimeGateway(payable(address(proxy)));
        blend = new MockERC20Token("Blend", "BLEND", 1_000_000 ether, user);

        vm.prank(admin);
        fluentRuntimeGateway.setOtherSideGateway(remoteGateway);

        _registerGateway(address(fluentRuntimeGateway));
        _registerGateway(remoteGateway);
    }

    function test_initialize_setsDefaults() public view {
        assertEq(fluentRuntimeGateway.owner(), admin);
        assertEq(fluentRuntimeGateway.getBridgeContract(), address(bridge));
        assertEq(fluentRuntimeGateway.getOtherSideGateway(), remoteGateway);
        (
            address blendToken,
            address configuredRecipient,
            uint256 deployBaseFee,
            uint256 deployFeePerByte,
            uint256 invokeBaseFee,
            uint256 invokeFeePerByte
        ) = fluentRuntimeGateway.getBlendFeeConfig();
        assertEq(blendToken, address(0));
        assertEq(configuredRecipient, address(0));
        assertEq(deployBaseFee, 0);
        assertEq(deployFeePerByte, 0);
        assertEq(invokeBaseFee, 0);
        assertEq(invokeFeePerByte, 0);
    }

    function test_setBlendFeeConfig_updatesQuoteRates() public {
        vm.prank(admin);
        fluentRuntimeGateway.setBlendFeeConfig(address(blend), feeRecipient, 1 ether, 2 ether, 3 ether, 4 ether);

        assertEq(fluentRuntimeGateway.quoteDeployFee(hex"010203", hex"0405"), 11 ether);
        assertEq(fluentRuntimeGateway.quoteInvokeFee(hex"010203"), 15 ether);
    }

    function test_requestDeploy_sendsBridgeMessageAndLocksValue() public {
        bytes memory wasmBytecode = hex"0061736d";
        bytes memory constructorCalldata = abi.encode(uint256(42));
        uint256 value = 0.25 ether;
        vm.deal(user, value);

        vm.prank(user);
        bytes32 requestId = fluentRuntimeGateway.requestDeploy{value: value}(wasmBytecode, constructorCalldata);

        assertEq(address(bridge).balance, value);
        assertEq(fluentRuntimeGateway.getNextRequestNonce(), 1);
        assertEq(requestId, keccak256(abi.encode(address(fluentRuntimeGateway), block.chainid, user, uint256(0))));
    }

    function test_requestDeploy_chargesBlendFee() public {
        bytes memory wasmBytecode = hex"0061736d";
        bytes memory constructorCalldata = abi.encode(uint256(42));
        uint256 expectedFee = 1 ether + (wasmBytecode.length + constructorCalldata.length) * 0.1 ether;

        vm.prank(admin);
        fluentRuntimeGateway.setBlendFeeConfig(address(blend), feeRecipient, 1 ether, 0.1 ether, 2 ether, 0.2 ether);
        vm.prank(user);
        blend.approve(address(fluentRuntimeGateway), expectedFee);

        vm.prank(user);
        fluentRuntimeGateway.requestDeploy(wasmBytecode, constructorCalldata);

        assertEq(blend.balanceOf(feeRecipient), expectedFee);
    }

    function test_requestDeploy_revertsWhenBlendFeeConfiguredWithoutToken() public {
        vm.prank(admin);
        fluentRuntimeGateway.setBlendFeeConfig(address(0), feeRecipient, 1 ether, 0, 0, 0);

        vm.prank(user);
        vm.expectRevert(IFluentRuntimeGatewayErrors.BlendFeeNotConfigured.selector);
        fluentRuntimeGateway.requestDeploy(hex"0061736d", "");
    }

    function test_requestDeploy_revertsForEmptyBytecode() public {
        vm.prank(user);
        vm.expectRevert(IFluentRuntimeGatewayErrors.EmptyWasmBytecode.selector);
        fluentRuntimeGateway.requestDeploy("", "");
    }

    function test_requestDeploy_withoutOtherSideGateway_revertsOnUnregisteredDestination() public {
        FluentRuntimeGateway impl = new FluentRuntimeGateway();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(FluentRuntimeGateway.initialize, (admin, address(bridge))));
        FluentRuntimeGateway localGateway = FluentRuntimeGateway(payable(address(proxy)));

        vm.prank(user);
        vm.expectRevert(IFluentBridgeErrors.GatewayNotWhitelisted.selector);
        localGateway.requestDeploy(hex"0061736d", "");
    }

    function test_requestInvoke_sendsBridgeMessageAndLocksValue() public {
        address wasmContract = makeAddr("wasmContract");
        bytes memory calldataPayload = abi.encodeWithSignature("run(uint256)", 7);
        uint256 value = 0.1 ether;
        vm.deal(user, value);

        vm.prank(user);
        bytes32 requestId = fluentRuntimeGateway.requestInvoke{value: value}(wasmContract, calldataPayload);

        assertEq(address(bridge).balance, value);
        assertEq(fluentRuntimeGateway.getNextRequestNonce(), 1);
        assertEq(requestId, keccak256(abi.encode(address(fluentRuntimeGateway), block.chainid, user, uint256(0))));
    }

    function test_requestInvoke_chargesBlendFee() public {
        address wasmContract = makeAddr("wasmContract");
        bytes memory calldataPayload = abi.encodeWithSignature("run(uint256)", 7);
        uint256 expectedFee = 2 ether + calldataPayload.length * 0.2 ether;

        vm.prank(admin);
        fluentRuntimeGateway.setBlendFeeConfig(address(blend), feeRecipient, 1 ether, 0.1 ether, 2 ether, 0.2 ether);
        vm.prank(user);
        blend.approve(address(fluentRuntimeGateway), expectedFee);

        vm.prank(user);
        fluentRuntimeGateway.requestInvoke(wasmContract, calldataPayload);

        assertEq(blend.balanceOf(feeRecipient), expectedFee);
    }

    function test_requestInvoke_revertsForZeroWasmContract() public {
        vm.prank(user);
        vm.expectRevert(IFluentRuntimeGatewayErrors.InvalidWasmContract.selector);
        fluentRuntimeGateway.requestInvoke(address(0), "");
    }

    function test_receiveDeployRequest_viaBridge_usesNativeCreate() public {
        bytes memory wasmBytecode = type(NativeWasmDeployTarget).creationCode;
        bytes memory constructorCalldata = abi.encode(uint256(42));
        uint256 value = 0.4 ether;
        bytes32 requestId = keccak256("deploy-request");
        bytes memory message = abi.encodeCall(
            FluentRuntimeGateway.receiveDeployRequest, (requestId, user, address(0), wasmBytecode, constructorCalldata)
        );

        vm.recordLogs();
        bytes32 messageHash = _relayWasmMessage(remoteGateway, address(fluentRuntimeGateway), value, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
        IFluentRuntimeGateway.ExecutionResult memory result = fluentRuntimeGateway.getExecutionResult(requestId);
        address deployed = abi.decode(result.returnData, (address));
        assertTrue(result.received);
        assertTrue(result.success);
        assertEq(deployed.code.length > 0, true);
        assertEq(deployed.balance, value);
        assertEq(NativeWasmDeployTarget(payable(deployed)).initialValue(), 42);
        assertTrue(result.responseSent);
        _assertResponseSent(requestId, true, result.returnData);
    }

    function test_receiveInvokeRequest_viaBridge_callsWasmContractAndStoresResponse() public {
        NativeWasmInvokeTarget wasmContract = new NativeWasmInvokeTarget();
        bytes memory calldataPayload = abi.encodeCall(NativeWasmInvokeTarget.run, (hex"1234"));
        bytes memory expectedReturn = abi.encode(uint256(123));
        bytes32 requestId = keccak256("invoke-request");
        uint256 value = 0.05 ether;
        bytes memory message = abi.encodeCall(
            FluentRuntimeGateway.receiveInvokeRequest,
            (requestId, user, address(0), address(wasmContract), calldataPayload)
        );

        vm.recordLogs();
        bytes32 messageHash = _relayWasmMessage(remoteGateway, address(fluentRuntimeGateway), value, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(wasmContract.lastValue(), value);
        assertEq(wasmContract.lastPayload(), hex"1234");
        _assertStoredResult(requestId, true, expectedReturn, true);
        _assertResponseSent(requestId, true, expectedReturn);
    }

    function test_receiveInvokeRequest_sendsStoredResponseImmediately() public {
        NativeWasmInvokeTarget wasmContract = new NativeWasmInvokeTarget();
        bytes32 requestId = keccak256("stored-response");
        bytes memory expectedReturn = abi.encode(uint256(123));
        bytes memory message = abi.encodeCall(
            FluentRuntimeGateway.receiveInvokeRequest,
            (requestId, user, address(0), address(wasmContract), abi.encodeCall(NativeWasmInvokeTarget.run, (hex"")))
        );
        uint256 outboundNonceBefore = bridge.getNonce();

        vm.recordLogs();
        _relayWasmMessage(remoteGateway, address(fluentRuntimeGateway), 0, message);

        _assertResponseSent(requestId, true, expectedReturn);
        IFluentRuntimeGateway.ExecutionResult memory result = fluentRuntimeGateway.getExecutionResult(requestId);
        assertTrue(result.responseSent);
        assertEq(bridge.getNonce(), outboundNonceBefore + 1);
    }

    function test_receiveRequest_fromWrongGateway_marksFailed() public {
        bytes memory message = abi.encodeCall(
            FluentRuntimeGateway.receiveDeployRequest, (keccak256("request"), user, address(0), hex"0061736d", "")
        );

        bytes32 messageHash =
            _relayWasmMessage(makeAddr("wrongRemoteGateway"), address(fluentRuntimeGateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_receiveDeployRequest_invalidNativeCreate_sendsFailedResponse() public {
        bytes32 requestId = keccak256("invalid-create");
        bytes memory message = abi.encodeCall(
            FluentRuntimeGateway.receiveDeployRequest, (requestId, user, address(0), hex"60006000fd", "")
        );

        bytes32 messageHash = _relayWasmMessage(remoteGateway, address(fluentRuntimeGateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
        _assertStoredResult(
            requestId, false, abi.encodeWithSelector(IFluentRuntimeGatewayErrors.NativeWasmDeployFailed.selector), true
        );
    }

    function test_receiveInvokeRequest_wasmRevert_sendsFailedResponse() public {
        NativeWasmInvokeTarget wasmContract = new NativeWasmInvokeTarget();
        bytes32 requestId = keccak256("wasm-revert");
        bytes memory message = abi.encodeCall(
            FluentRuntimeGateway.receiveInvokeRequest,
            (requestId, user, address(0), address(wasmContract), abi.encodeCall(NativeWasmInvokeTarget.fail, ()))
        );

        bytes32 messageHash = _relayWasmMessage(remoteGateway, address(fluentRuntimeGateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
        _assertStoredResult(requestId, false, _runtimeRevertData(), true);
    }

    function test_receiveInvokeRequest_reentrantWasmCannotCreateOutboundRequest() public {
        ReenteringWasmInvokeTarget wasmContract = new ReenteringWasmInvokeTarget(fluentRuntimeGateway);
        bytes32 requestId = keccak256("reentrant-wasm");
        bytes memory expectedReturn = abi.encode(REENTRANCY_GUARD_REENTRANT_CALL);
        bytes memory message = abi.encodeCall(
            FluentRuntimeGateway.receiveInvokeRequest,
            (requestId, user, address(0), address(wasmContract), abi.encodeCall(ReenteringWasmInvokeTarget.run, ()))
        );

        bytes32 messageHash = _relayWasmMessage(remoteGateway, address(fluentRuntimeGateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(wasmContract.caughtSelector(), REENTRANCY_GUARD_REENTRANT_CALL);
        assertEq(fluentRuntimeGateway.getNextRequestNonce(), 0);
        _assertStoredResult(requestId, true, expectedReturn, true);
    }

    function test_receiveExecutionResult_viaBridge_storesResult() public {
        bytes32 requestId = keccak256("result");
        bytes memory returnData = abi.encode(address(0xBEEF));
        bytes memory message = abi.encodeCall(
            FluentRuntimeGateway.receiveExecutionResult, (requestId, user, address(0), true, returnData)
        );

        bytes32 messageHash = _relayWasmMessage(remoteGateway, address(fluentRuntimeGateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
        IFluentRuntimeGateway.ExecutionResult memory result = fluentRuntimeGateway.getExecutionResult(requestId);
        assertTrue(result.received);
        assertTrue(result.success);
        assertEq(result.requester, user);
        assertEq(result.responseHandler, address(0));
        assertFalse(result.responseSent);
        assertEq(result.returnData, returnData);
    }

    function test_receiveExecutionResult_withHandler_storesAndCallsHandler() public {
        RecordingFluentRuntimeResponseHandler handler = new RecordingFluentRuntimeResponseHandler();
        bytes32 requestId = keccak256("handler-result");
        bytes memory returnData = abi.encode(uint256(123));
        bytes memory message = abi.encodeCall(
            FluentRuntimeGateway.receiveExecutionResult, (requestId, user, address(handler), true, returnData)
        );

        bytes32 messageHash = _relayWasmMessage(remoteGateway, address(fluentRuntimeGateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
        IFluentRuntimeGateway.ExecutionResult memory result = fluentRuntimeGateway.getExecutionResult(requestId);
        assertTrue(result.received);
        assertEq(result.responseHandler, address(handler));
        assertFalse(result.responseSent);
        assertEq(handler.lastRequestId(), requestId);
        assertEq(handler.lastRequester(), user);
        assertTrue(handler.lastSuccess());
        assertEq(handler.lastReturnData(), returnData);
    }

    function test_receiveExecutionResult_reentrantHandlerCannotCreateOutboundRequest() public {
        ReenteringFluentRuntimeResponseHandler handler =
            new ReenteringFluentRuntimeResponseHandler(fluentRuntimeGateway);
        bytes32 requestId = keccak256("reentrant-handler");
        bytes memory message = abi.encodeCall(
            FluentRuntimeGateway.receiveExecutionResult, (requestId, user, address(handler), true, hex"01")
        );

        bytes32 messageHash = _relayWasmMessage(remoteGateway, address(fluentRuntimeGateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(handler.caughtSelector(), REENTRANCY_GUARD_REENTRANT_CALL);
        assertEq(fluentRuntimeGateway.getNextRequestNonce(), 0);
    }

    function test_receiveExecutionResult_duplicate_marksFailed() public {
        bytes32 requestId = keccak256("duplicate-result");
        bytes memory message =
            abi.encodeCall(FluentRuntimeGateway.receiveExecutionResult, (requestId, user, address(0), true, hex"01"));

        _relayWasmMessage(remoteGateway, address(fluentRuntimeGateway), 0, message);
        bytes32 secondHash = _relayWasmMessage(remoteGateway, address(fluentRuntimeGateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(secondHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_receiveDeployRequest_directCall_reverts() public {
        vm.prank(user);
        vm.expectRevert(IGatewayBaseErrors.OnlyFluentBridge.selector);
        fluentRuntimeGateway.receiveDeployRequest(keccak256("request"), user, address(0), hex"0061736d", "");
    }

    function _relayWasmMessage(address from, address to, uint256 value, bytes memory message)
        internal
        returns (bytes32 messageHash)
    {
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        messageHash = _bridgeMessageHash(from, to, value, sourceChainId, sourceBlock, nonce, message);

        vm.deal(address(bridge), address(bridge).balance + value);
        vm.prank(relayer);
        bridge.receiveMessage(from, to, value, sourceChainId, sourceBlock, nonce, message);
    }

    function _assertResponseSent(bytes32 requestId, bool success, bytes memory returnData) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("FluentRuntimeExecutionResponseSent(bytes32,address,bool,bytes32)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(fluentRuntimeGateway) && logs[i].topics[0] == topic) {
                assertEq(logs[i].topics[1], requestId);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), user);
                (bool emittedSuccess, bytes32 returnDataHash) = abi.decode(logs[i].data, (bool, bytes32));
                assertEq(emittedSuccess, success);
                assertEq(returnDataHash, keccak256(returnData));
                return;
            }
        }
        revert("response event not found");
    }

    function _assertStoredResult(bytes32 requestId, bool success, bytes memory returnData, bool responseSent)
        internal
        view
    {
        IFluentRuntimeGateway.ExecutionResult memory result = fluentRuntimeGateway.getExecutionResult(requestId);
        assertTrue(result.received);
        assertEq(result.success, success);
        assertEq(result.requester, user);
        assertEq(result.responseHandler, address(0));
        assertEq(result.responseSent, responseSent);
        assertEq(result.returnData, returnData);
    }

    function _runtimeRevertData() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", "RUNTIME_REVERT");
    }
}
