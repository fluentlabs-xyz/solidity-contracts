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
import {MockFluentRuntime} from "../mocks/MockFluentRuntime.sol";

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

contract FluentRuntimeGatewayTest is GatewayBase {
    FluentRuntimeGateway internal fluentRuntimeGateway;
    MockFluentRuntime internal runtime;

    function setUp() public override {
        super.setUp();
        _deployBridge(0);
        _deployFluentRuntimeGateway();
    }

    function _deployFluentRuntimeGateway() internal {
        runtime = new MockFluentRuntime();
        FluentRuntimeGateway impl = new FluentRuntimeGateway();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(FluentRuntimeGateway.initialize, (admin, address(bridge), address(runtime)))
        );
        fluentRuntimeGateway = FluentRuntimeGateway(payable(address(proxy)));

        vm.prank(admin);
        fluentRuntimeGateway.setOtherSideGateway(remoteGateway);

        _registerGateway(address(fluentRuntimeGateway));
        _registerGateway(remoteGateway);
    }

    function test_initialize_setsDefaults() public view {
        assertEq(fluentRuntimeGateway.owner(), admin);
        assertEq(fluentRuntimeGateway.getBridgeContract(), address(bridge));
        assertEq(fluentRuntimeGateway.getOtherSideGateway(), remoteGateway);
        assertEq(fluentRuntimeGateway.getRuntime(), address(runtime));
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

    function test_requestDeploy_revertsForEmptyBytecode() public {
        vm.prank(user);
        vm.expectRevert(IFluentRuntimeGatewayErrors.EmptyWasmBytecode.selector);
        fluentRuntimeGateway.requestDeploy("", "");
    }

    function test_requestDeploy_withoutOtherSideGateway_revertsOnUnregisteredDestination() public {
        FluentRuntimeGateway impl = new FluentRuntimeGateway();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(FluentRuntimeGateway.initialize, (admin, address(bridge), address(runtime)))
        );
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

    function test_requestInvoke_revertsForZeroWasmContract() public {
        vm.prank(user);
        vm.expectRevert(IFluentRuntimeGatewayErrors.InvalidWasmContract.selector);
        fluentRuntimeGateway.requestInvoke(address(0), "");
    }

    function test_receiveDeployRequest_viaBridge_callsRuntime() public {
        bytes memory wasmBytecode = hex"0061736d01000000";
        bytes memory constructorCalldata = abi.encode("init");
        uint256 value = 0.4 ether;
        bytes32 requestId = keccak256("deploy-request");
        bytes memory message = abi.encodeCall(
            FluentRuntimeGateway.receiveDeployRequest, (requestId, user, address(0), wasmBytecode, constructorCalldata)
        );

        bytes32 messageHash = _relayWasmMessage(remoteGateway, address(fluentRuntimeGateway), value, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(runtime.lastRequester(), user);
        assertEq(runtime.lastValue(), value);
        assertEq(runtime.lastWasmHash(), keccak256(wasmBytecode));
        assertEq(runtime.lastConstructorCalldata(), constructorCalldata);
        _assertStoredResult(requestId, true, abi.encode(runtime.lastWasmContract()));
    }

    function test_receiveInvokeRequest_viaBridge_callsRuntimeAndStoresResponse() public {
        address wasmContract = makeAddr("wasmContract");
        bytes memory calldataPayload = abi.encodeWithSignature("run(bytes)", hex"1234");
        bytes memory expectedReturn = abi.encode(uint256(123));
        bytes32 requestId = keccak256("invoke-request");
        uint256 value = 0.05 ether;
        runtime.setNextInvokeReturnData(expectedReturn);
        bytes memory message = abi.encodeCall(
            FluentRuntimeGateway.receiveInvokeRequest, (requestId, user, address(0), wasmContract, calldataPayload)
        );

        bytes32 messageHash = _relayWasmMessage(remoteGateway, address(fluentRuntimeGateway), value, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(runtime.lastRequester(), user);
        assertEq(runtime.lastWasmContract(), wasmContract);
        assertEq(runtime.lastValue(), value);
        assertEq(runtime.lastCalldataPayload(), calldataPayload);
        _assertStoredResult(requestId, true, expectedReturn);
    }

    function test_sendExecutionResult_sendsStoredResponse() public {
        bytes32 requestId = keccak256("stored-response");
        bytes memory expectedReturn = abi.encode(uint256(123));
        bytes memory message = abi.encodeCall(
            FluentRuntimeGateway.receiveInvokeRequest,
            (requestId, user, address(0), makeAddr("wasmContract"), abi.encodeWithSignature("run()"))
        );
        runtime.setNextInvokeReturnData(expectedReturn);
        _relayWasmMessage(remoteGateway, address(fluentRuntimeGateway), 0, message);

        vm.recordLogs();
        fluentRuntimeGateway.sendExecutionResult(requestId);

        _assertResponseSent(requestId, true, expectedReturn);
        IFluentRuntimeGateway.ExecutionResult memory result = fluentRuntimeGateway.getExecutionResult(requestId);
        assertTrue(result.responseSent);
    }

    function test_receiveRequest_fromWrongGateway_marksFailed() public {
        bytes memory message = abi.encodeCall(
            FluentRuntimeGateway.receiveDeployRequest, (keccak256("request"), user, address(0), hex"0061736d", "")
        );

        bytes32 messageHash =
            _relayWasmMessage(makeAddr("wrongRemoteGateway"), address(fluentRuntimeGateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_receiveDeployRequest_withoutRuntime_marksFailed() public {
        vm.prank(admin);
        fluentRuntimeGateway.setRuntime(address(0));
        bytes32 requestId = keccak256("missing-runtime");
        bytes memory message =
            abi.encodeCall(FluentRuntimeGateway.receiveDeployRequest, (requestId, user, address(0), hex"0061736d", ""));

        bytes32 messageHash = _relayWasmMessage(remoteGateway, address(fluentRuntimeGateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
        _assertStoredResult(
            requestId, false, abi.encodeWithSelector(IFluentRuntimeGatewayErrors.RuntimeNotConfigured.selector)
        );
    }

    function test_receiveDeployRequest_runtimeRevert_sendsFailedResponse() public {
        runtime.setShouldRevert(true);
        bytes32 requestId = keccak256("runtime-revert");
        bytes memory message =
            abi.encodeCall(FluentRuntimeGateway.receiveDeployRequest, (requestId, user, address(0), hex"0061736d", ""));

        bytes32 messageHash = _relayWasmMessage(remoteGateway, address(fluentRuntimeGateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
        _assertStoredResult(requestId, false, _runtimeRevertData());
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

    function _assertStoredResult(bytes32 requestId, bool success, bytes memory returnData) internal view {
        IFluentRuntimeGateway.ExecutionResult memory result = fluentRuntimeGateway.getExecutionResult(requestId);
        assertTrue(result.received);
        assertEq(result.success, success);
        assertEq(result.requester, user);
        assertEq(result.responseHandler, address(0));
        assertFalse(result.responseSent);
        assertEq(result.returnData, returnData);
    }

    function _runtimeRevertData() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", "RUNTIME_REVERT");
    }
}
