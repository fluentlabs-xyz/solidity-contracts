// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IFluentRuntime} from "../../contracts/interfaces/gateways/IFluentRuntimeGateway.sol";

contract MockFluentRuntime is IFluentRuntime {
    address public lastRequester;
    address public lastWasmContract;
    uint256 public lastValue;
    bytes32 public lastWasmHash;
    bytes public lastConstructorCalldata;
    bytes public lastCalldataPayload;
    bytes public nextInvokeReturnData;
    bool public shouldRevert;

    function setNextInvokeReturnData(bytes calldata data) external {
        nextInvokeReturnData = data;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function deployWasm(address requester, bytes calldata wasmBytecode, bytes calldata constructorCalldata)
        external
        payable
        returns (address contractAddress)
    {
        require(!shouldRevert, "RUNTIME_REVERT");
        lastRequester = requester;
        lastValue = msg.value;
        lastWasmHash = keccak256(wasmBytecode);
        lastConstructorCalldata = constructorCalldata;
        contractAddress = address(uint160(uint256(keccak256(abi.encode(requester, wasmBytecode, constructorCalldata)))));
        lastWasmContract = contractAddress;
    }

    function invokeWasm(address requester, address wasmContract, bytes calldata calldataPayload)
        external
        payable
        returns (bytes memory returnData)
    {
        require(!shouldRevert, "RUNTIME_REVERT");
        lastRequester = requester;
        lastWasmContract = wasmContract;
        lastValue = msg.value;
        lastCalldataPayload = calldataPayload;
        return nextInvokeReturnData;
    }
}
