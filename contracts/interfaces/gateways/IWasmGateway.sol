// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

interface IFluentWasmRuntime {
    function deployWasm(address requester, bytes calldata wasmBytecode, bytes calldata constructorCalldata)
        external
        payable
        returns (address contractAddress);

    function invokeWasm(address requester, address wasmContract, bytes calldata calldataPayload)
        external
        payable
        returns (bytes memory returnData);
}

interface IWasmGatewayErrors {
    error EmptyWasmBytecode();
    error InvalidWasmContract();
    error RuntimeNotConfigured();
    error RuntimeCallFailed(bytes returnData);
}

interface IWasmGatewayEvents {
    event RuntimeUpdated(address indexed prevValue, address indexed newValue);
    event WasmDeployRequested(address indexed requester, uint256 value, bytes32 payloadHash);
    event WasmInvokeRequested(
        address indexed requester, address indexed wasmContract, uint256 value, bytes32 payloadHash
    );
    event WasmDeployed(address indexed requester, address indexed wasmContract, uint256 value);
    event WasmInvoked(address indexed requester, address indexed wasmContract, uint256 value, bytes returnData);
}

interface IWasmGateway is IWasmGatewayErrors, IWasmGatewayEvents {
    function getRuntime() external view returns (address);
    function setRuntime(address newRuntime) external;
    function requestDeploy(bytes calldata wasmBytecode, bytes calldata constructorCalldata) external payable;
    function requestInvoke(address wasmContract, bytes calldata calldataPayload) external payable;
    function receiveDeployRequest(address requester, bytes calldata wasmBytecode, bytes calldata constructorCalldata)
        external
        payable;
    function receiveInvokeRequest(address requester, address wasmContract, bytes calldata calldataPayload)
        external
        payable;
}
