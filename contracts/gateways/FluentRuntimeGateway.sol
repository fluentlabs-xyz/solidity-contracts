// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {GatewayBase} from "./GatewayBase.sol";
import {FluentBridge} from "../bridge/FluentBridge.sol";
import {
    IFluentRuntime,
    IFluentRuntimeGateway,
    IFluentRuntimeResponseHandler
} from "../interfaces/gateways/IFluentRuntimeGateway.sol";

/**
 * @title FluentRuntimeGateway
 * @notice Bridge gateway for Ethereum-originated Fluent Runtime deploy and invoke requests.
 * @dev Source-chain users submit the Fluent Runtime payload plus native value for runtime execution.
 *      The existing FluentBridge message lifecycle then handles relay delivery, failure
 *      recording, and retry. On the destination chain, this gateway verifies the remote
 *      gateway sender, forwards the request to the configured Fluent Runtime endpoint,
 *      and stores the execution result for a follow-up response message back to the source gateway.
 */
contract FluentRuntimeGateway is GatewayBase, IFluentRuntimeGateway {
    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.FluentRuntimeGatewayStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FLUENT_RUNTIME_GATEWAY_STORAGE_LOCATION =
        0x2807da62fe306b92f6c239ad34f50ac03f4b03d7d4316b1c510c1b590f8eb400;

    /// @custom:storage-location erc7201:Fluent.storage.FluentRuntimeGatewayStorage
    struct FluentRuntimeGatewayStorage {
        address _runtime;
        uint256 _nextRequestNonce;
        mapping(bytes32 requestId => ExecutionResult result) _executionResults;
        uint256[47] __gap;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address bridgeContract, address runtime) external initializer {
        __GatewayBase_init(initialOwner, bridgeContract);
        _setRuntime(runtime);
    }

    function requestDeploy(bytes calldata wasmBytecode, bytes calldata constructorCalldata)
        external
        payable
        nonReentrant
        returns (bytes32 requestId)
    {
        return _requestDeploy(wasmBytecode, constructorCalldata, address(0));
    }

    function requestDeployWithHandler(
        bytes calldata wasmBytecode,
        bytes calldata constructorCalldata,
        address responseHandler
    ) external payable nonReentrant returns (bytes32 requestId) {
        return _requestDeploy(wasmBytecode, constructorCalldata, responseHandler);
    }

    function requestInvoke(address wasmContract, bytes calldata calldataPayload)
        external
        payable
        nonReentrant
        returns (bytes32 requestId)
    {
        return _requestInvoke(wasmContract, calldataPayload, address(0));
    }

    function requestInvokeWithHandler(address wasmContract, bytes calldata calldataPayload, address responseHandler)
        external
        payable
        nonReentrant
        returns (bytes32 requestId)
    {
        return _requestInvoke(wasmContract, calldataPayload, responseHandler);
    }

    function receiveDeployRequest(
        bytes32 requestId,
        address requester,
        address responseHandler,
        bytes calldata wasmBytecode,
        bytes calldata constructorCalldata
    ) external payable onlyFluentBridge nonReentrant {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(requestId != bytes32(0), InvalidRequestId());
        require(requester != address(0), InvalidRecipient());
        require(wasmBytecode.length != 0, EmptyWasmBytecode());

        (bool success, bytes memory returnData) = _callDeployRuntime(requester, wasmBytecode, constructorCalldata);
        _recordExecutionResult(requestId, requester, responseHandler, success, returnData, false);
    }

    function receiveInvokeRequest(
        bytes32 requestId,
        address requester,
        address responseHandler,
        address wasmContract,
        bytes calldata calldataPayload
    ) external payable onlyFluentBridge nonReentrant {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(requestId != bytes32(0), InvalidRequestId());
        require(requester != address(0), InvalidRecipient());
        require(wasmContract != address(0), InvalidWasmContract());

        (bool success, bytes memory resultData) = _callInvokeRuntime(requester, wasmContract, calldataPayload);
        _recordExecutionResult(requestId, requester, responseHandler, success, resultData, false);
    }

    function receiveExecutionResult(
        bytes32 requestId,
        address requester,
        address responseHandler,
        bool success,
        bytes calldata returnData
    ) external payable onlyFluentBridge nonReentrant {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(requestId != bytes32(0), InvalidRequestId());
        require(requester != address(0), InvalidRecipient());

        _recordExecutionResult(requestId, requester, responseHandler, success, returnData, true);
    }

    function sendExecutionResult(bytes32 requestId) external payable nonReentrant {
        FluentRuntimeGatewayStorage storage $ = _getFluentRuntimeGatewayStorage();
        ExecutionResult storage result = $._executionResults[requestId];
        require(result.received, ResultNotReady(requestId));
        require(!result.responseSent, ResultAlreadySent(requestId));

        result.responseSent = true;
        bytes memory message = abi.encodeCall(
            FluentRuntimeGateway.receiveExecutionResult,
            (requestId, result.requester, result.responseHandler, result.success, result.returnData)
        );
        FluentBridge bridge = FluentBridge(getBridgeContract());
        uint256 fee = bridge.getSentMessageFee();
        require(msg.value == fee, ExactFeeRequired());
        bridge.sendMessage{value: msg.value}(getOtherSideGateway(), message);

        emit FluentRuntimeExecutionResponseSent(
            requestId, result.requester, result.success, keccak256(result.returnData)
        );
    }

    function _recordExecutionResult(
        bytes32 requestId,
        address requester,
        address responseHandler,
        bool success,
        bytes memory returnData,
        bool callHandler
    ) internal {
        FluentRuntimeGatewayStorage storage $ = _getFluentRuntimeGatewayStorage();
        require(!$._executionResults[requestId].received, ResultAlreadyReceived(requestId));
        $._executionResults[requestId] = ExecutionResult({
            received: true,
            success: success,
            requester: requester,
            responseHandler: responseHandler,
            responseSent: false,
            returnData: returnData
        });

        if (callHandler) {
            emit FluentRuntimeExecutionResultReceived(requestId, requester, responseHandler, success, returnData);
        } else {
            emit FluentRuntimeExecutionResultReady(requestId, requester, responseHandler, success, returnData);
        }

        if (callHandler && responseHandler != address(0)) {
            (bool handlerSuccess, bytes memory handlerReturnData) = responseHandler.call(
                abi.encodeCall(
                    IFluentRuntimeResponseHandler.handleFluentRuntimeResult, (requestId, requester, success, returnData)
                )
            );
            emit FluentRuntimeExecutionResultHandlerCalled(
                requestId, responseHandler, handlerSuccess, handlerReturnData
            );
        }
    }

    function getRuntime() public view returns (address) {
        return _getFluentRuntimeGatewayStorage()._runtime;
    }

    function getNextRequestNonce() public view returns (uint256) {
        return _getFluentRuntimeGatewayStorage()._nextRequestNonce;
    }

    function getExecutionResult(bytes32 requestId) public view returns (ExecutionResult memory) {
        return _getFluentRuntimeGatewayStorage()._executionResults[requestId];
    }

    function setRuntime(address newRuntime) external onlyOwner {
        _setRuntime(newRuntime);
    }

    function _requestDeploy(bytes calldata wasmBytecode, bytes calldata constructorCalldata, address responseHandler)
        internal
        returns (bytes32 requestId)
    {
        require(wasmBytecode.length != 0, EmptyWasmBytecode());

        address requester = msg.sender;
        requestId = _takeNextRequestId(requester);
        bytes memory message = abi.encodeCall(
            FluentRuntimeGateway.receiveDeployRequest,
            (requestId, requester, responseHandler, wasmBytecode, constructorCalldata)
        );
        FluentBridge(getBridgeContract()).sendMessage{value: msg.value}(getOtherSideGateway(), message);

        emit FluentRuntimeDeployRequested(
            requestId, requester, responseHandler, msg.value, keccak256(abi.encode(wasmBytecode, constructorCalldata))
        );
    }

    function _requestInvoke(address wasmContract, bytes calldata calldataPayload, address responseHandler)
        internal
        returns (bytes32 requestId)
    {
        require(wasmContract != address(0), InvalidWasmContract());

        address requester = msg.sender;
        requestId = _takeNextRequestId(requester);
        bytes memory message = abi.encodeCall(
            FluentRuntimeGateway.receiveInvokeRequest,
            (requestId, requester, responseHandler, wasmContract, calldataPayload)
        );
        FluentBridge(getBridgeContract()).sendMessage{value: msg.value}(getOtherSideGateway(), message);

        emit FluentRuntimeInvokeRequested(
            requestId, requester, wasmContract, responseHandler, msg.value, keccak256(calldataPayload)
        );
    }

    function _callDeployRuntime(address requester, bytes calldata wasmBytecode, bytes calldata constructorCalldata)
        internal
        returns (bool success, bytes memory returnData)
    {
        address runtime = getRuntime();
        if (runtime == address(0)) {
            return (false, abi.encodeWithSelector(RuntimeNotConfigured.selector));
        }

        return runtime.call{value: msg.value}(
            abi.encodeCall(IFluentRuntime.deployWasm, (requester, wasmBytecode, constructorCalldata))
        );
    }

    function _callInvokeRuntime(address requester, address wasmContract, bytes calldata calldataPayload)
        internal
        returns (bool success, bytes memory resultData)
    {
        address runtime = getRuntime();
        if (runtime == address(0)) {
            return (false, abi.encodeWithSelector(RuntimeNotConfigured.selector));
        }

        (success, resultData) = runtime.call{value: msg.value}(
            abi.encodeCall(IFluentRuntime.invokeWasm, (requester, wasmContract, calldataPayload))
        );
        if (success) {
            resultData = abi.decode(resultData, (bytes));
        }
    }

    function _takeNextRequestId(address requester) internal returns (bytes32 requestId) {
        FluentRuntimeGatewayStorage storage $ = _getFluentRuntimeGatewayStorage();
        uint256 nonce = $._nextRequestNonce++;
        requestId = keccak256(abi.encode(address(this), block.chainid, requester, nonce));
    }

    function _setRuntime(address newRuntime) internal {
        FluentRuntimeGatewayStorage storage $ = _getFluentRuntimeGatewayStorage();
        emit RuntimeUpdated($._runtime, newRuntime);
        $._runtime = newRuntime;
    }

    receive() external payable {}

    function _getFluentRuntimeGatewayStorage() private pure returns (FluentRuntimeGatewayStorage storage $) {
        assembly ("memory-safe") {
            $.slot := FLUENT_RUNTIME_GATEWAY_STORAGE_LOCATION
        }
    }
}
