// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {GatewayBase} from "./GatewayBase.sol";
import {FluentBridge} from "../bridge/FluentBridge.sol";
import {IFluentWasmRuntime, IWasmGateway} from "../interfaces/gateways/IWasmGateway.sol";

/**
 * @title WasmGateway
 * @notice Bridge gateway for Ethereum-originated Fluent Runtime WASM deploy and invoke requests.
 * @dev Source-chain users submit the WASM payload plus native value for runtime execution.
 *      The existing FluentBridge message lifecycle then handles relay delivery, failure
 *      recording, and retry. On the destination chain, this gateway verifies the remote
 *      gateway sender and forwards the request to the configured Fluent Runtime endpoint.
 */
contract WasmGateway is GatewayBase, IWasmGateway {
    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.WasmGatewayStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WASM_GATEWAY_STORAGE_LOCATION =
        0x2807da62fe306b92f6c239ad34f50ac03f4b03d7d4316b1c510c1b590f8eb400;

    /// @custom:storage-location erc7201:Fluent.storage.WasmGatewayStorage
    struct WasmGatewayStorage {
        address _runtime;
        uint256[49] __gap;
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
    {
        require(wasmBytecode.length != 0, EmptyWasmBytecode());

        address requester = msg.sender;
        bytes memory message =
            abi.encodeCall(WasmGateway.receiveDeployRequest, (requester, wasmBytecode, constructorCalldata));
        FluentBridge(getBridgeContract()).sendMessage{value: msg.value}(getOtherSideGateway(), message);

        emit WasmDeployRequested(requester, msg.value, keccak256(abi.encode(wasmBytecode, constructorCalldata)));
    }

    function requestInvoke(address wasmContract, bytes calldata calldataPayload) external payable nonReentrant {
        require(wasmContract != address(0), InvalidWasmContract());

        address requester = msg.sender;
        bytes memory message =
            abi.encodeCall(WasmGateway.receiveInvokeRequest, (requester, wasmContract, calldataPayload));
        FluentBridge(getBridgeContract()).sendMessage{value: msg.value}(getOtherSideGateway(), message);

        emit WasmInvokeRequested(requester, wasmContract, msg.value, keccak256(calldataPayload));
    }

    function receiveDeployRequest(address requester, bytes calldata wasmBytecode, bytes calldata constructorCalldata)
        external
        payable
        onlyFluentBridge
        nonReentrant
    {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(requester != address(0), InvalidRecipient());
        require(wasmBytecode.length != 0, EmptyWasmBytecode());

        address runtime = _requireRuntime();
        (bool success, bytes memory returnData) = runtime.call{value: msg.value}(
            abi.encodeCall(IFluentWasmRuntime.deployWasm, (requester, wasmBytecode, constructorCalldata))
        );
        require(success, RuntimeCallFailed(returnData));

        address wasmContract = abi.decode(returnData, (address));
        emit WasmDeployed(requester, wasmContract, msg.value);
    }

    function receiveInvokeRequest(address requester, address wasmContract, bytes calldata calldataPayload)
        external
        payable
        onlyFluentBridge
        nonReentrant
    {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(requester != address(0), InvalidRecipient());
        require(wasmContract != address(0), InvalidWasmContract());

        address runtime = _requireRuntime();
        (bool success, bytes memory returnData) = runtime.call{value: msg.value}(
            abi.encodeCall(IFluentWasmRuntime.invokeWasm, (requester, wasmContract, calldataPayload))
        );
        require(success, RuntimeCallFailed(returnData));

        bytes memory decodedReturnData = abi.decode(returnData, (bytes));
        emit WasmInvoked(requester, wasmContract, msg.value, decodedReturnData);
    }

    function getRuntime() public view returns (address) {
        return _getWasmGatewayStorage()._runtime;
    }

    function setRuntime(address newRuntime) external onlyOwner {
        _setRuntime(newRuntime);
    }

    function _setRuntime(address newRuntime) internal {
        WasmGatewayStorage storage $ = _getWasmGatewayStorage();
        emit RuntimeUpdated($._runtime, newRuntime);
        $._runtime = newRuntime;
    }

    function _requireRuntime() internal view returns (address runtime) {
        runtime = getRuntime();
        require(runtime != address(0), RuntimeNotConfigured());
    }

    function _getWasmGatewayStorage() private pure returns (WasmGatewayStorage storage $) {
        assembly ("memory-safe") {
            $.slot := WASM_GATEWAY_STORAGE_LOCATION
        }
    }
}
