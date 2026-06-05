// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

interface IFluentRuntimeResponseHandler {
    function handleFluentRuntimeResult(bytes32 requestId, address requester, bool success, bytes calldata returnData)
        external;
}

interface IFluentRuntimeGatewayErrors {
    error EmptyWasmBytecode();
    error InvalidWasmContract();
    error InvalidRequestId();
    error NativeWasmDeployFailed();
    error ResultAlreadyReceived(bytes32 requestId);
    error InsufficientResponseFee(uint256 required, uint256 available);
}

interface IFluentRuntimeGatewayEvents {
    event FluentRuntimeDeployRequested(
        bytes32 indexed requestId,
        address indexed requester,
        address indexed responseHandler,
        uint256 value,
        bytes32 payloadHash
    );
    event FluentRuntimeInvokeRequested(
        bytes32 indexed requestId,
        address indexed requester,
        address indexed wasmContract,
        address responseHandler,
        uint256 value,
        bytes32 payloadHash
    );
    event FluentRuntimeExecutionResponseSent(
        bytes32 indexed requestId, address indexed requester, bool success, bytes32 returnDataHash
    );
    event FluentRuntimeExecutionResultReady(
        bytes32 indexed requestId,
        address indexed requester,
        address indexed responseHandler,
        bool success,
        bytes returnData
    );
    event FluentRuntimeExecutionResultReceived(
        bytes32 indexed requestId,
        address indexed requester,
        address indexed responseHandler,
        bool success,
        bytes returnData
    );
    event FluentRuntimeExecutionResultHandlerCalled(
        bytes32 indexed requestId, address indexed responseHandler, bool success, bytes returnData
    );
}

interface IFluentRuntimeGateway is IFluentRuntimeGatewayErrors, IFluentRuntimeGatewayEvents {
    struct ExecutionResult {
        bool received;
        bool success;
        address requester;
        address responseHandler;
        bool responseSent;
        bytes returnData;
    }

    function getNextRequestNonce() external view returns (uint256);
    function getExecutionResult(bytes32 requestId) external view returns (ExecutionResult memory);
    function requestDeploy(bytes calldata wasmBytecode, bytes calldata constructorCalldata)
        external
        payable
        returns (bytes32);
    function requestDeployWithHandler(
        bytes calldata wasmBytecode,
        bytes calldata constructorCalldata,
        address responseHandler
    ) external payable returns (bytes32);
    function requestInvoke(address wasmContract, bytes calldata calldataPayload) external payable returns (bytes32);
    function requestInvokeWithHandler(address wasmContract, bytes calldata calldataPayload, address responseHandler)
        external
        payable
        returns (bytes32);
    function receiveDeployRequest(
        bytes32 requestId,
        address requester,
        address responseHandler,
        bytes calldata wasmBytecode,
        bytes calldata constructorCalldata
    ) external payable;
    function receiveInvokeRequest(
        bytes32 requestId,
        address requester,
        address responseHandler,
        address wasmContract,
        bytes calldata calldataPayload
    ) external payable;
    function receiveExecutionResult(
        bytes32 requestId,
        address requester,
        address responseHandler,
        bool success,
        bytes calldata returnData
    ) external payable;
}
