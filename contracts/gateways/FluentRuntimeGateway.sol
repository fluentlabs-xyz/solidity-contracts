// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {GatewayBase} from "./GatewayBase.sol";
import {FluentBridge} from "../bridge/FluentBridge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFluentRuntimeGateway, IFluentRuntimeResponseHandler} from "../interfaces/gateways/IFluentRuntimeGateway.sol";

/**
 * @title FluentRuntimeGateway
 * @notice Bridge gateway for Ethereum-originated Fluent Runtime deploy and invoke requests.
 * @dev Source-chain users submit the Fluent Runtime payload plus native value for runtime execution.
 *      The existing FluentBridge message lifecycle then handles relay delivery, failure
 *      recording, and retry. On the destination chain, this gateway verifies the remote
 *      gateway sender, deploys WASM bytecode with native CREATE or invokes an existing
 *      WASM contract directly, and stores the execution result for a follow-up response
 *      message back to the source gateway.
 */
contract FluentRuntimeGateway is GatewayBase, IFluentRuntimeGateway {
    using SafeERC20 for IERC20;

    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.FluentRuntimeGatewayStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FLUENT_RUNTIME_GATEWAY_STORAGE_LOCATION =
        0x2807da62fe306b92f6c239ad34f50ac03f4b03d7d4316b1c510c1b590f8eb400;

    /// @custom:storage-location erc7201:Fluent.storage.FluentRuntimeGatewayStorage
    struct FluentRuntimeGatewayStorage {
        uint256 _nextRequestNonce;
        mapping(bytes32 requestId => ExecutionResult result) _executionResults;
        address _blendToken;
        address _feeRecipient;
        uint256 _deployBaseFee;
        uint256 _deployFeePerByte;
        uint256 _invokeBaseFee;
        uint256 _invokeFeePerByte;
        uint256[42] __gap;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address bridgeContract) external initializer {
        __GatewayBase_init(initialOwner, bridgeContract);
    }

    function setBlendFeeConfig(
        address blendToken,
        address feeRecipient,
        uint256 deployBaseFee,
        uint256 deployFeePerByte,
        uint256 invokeBaseFee,
        uint256 invokeFeePerByte
    ) external onlyOwner {
        _setBlendFeeConfig(blendToken, feeRecipient, deployBaseFee, deployFeePerByte, invokeBaseFee, invokeFeePerByte);
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

        bytes memory initCode = abi.encodePacked(wasmBytecode, constructorCalldata);
        address deployed;
        uint256 value = msg.value;
        assembly ("memory-safe") {
            deployed := create(value, add(initCode, 0x20), mload(initCode))
        }

        bool success = deployed != address(0);
        bytes memory returnData =
            success ? abi.encode(deployed) : abi.encodeWithSelector(NativeWasmDeployFailed.selector);

        FluentRuntimeGatewayStorage storage $ = _getFluentRuntimeGatewayStorage();
        require(!$._executionResults[requestId].received, ResultAlreadyReceived(requestId));
        $._executionResults[requestId] = ExecutionResult({
            received: true,
            success: success,
            requester: requester,
            responseHandler: responseHandler,
            responseSent: true,
            returnData: returnData
        });
        emit FluentRuntimeExecutionResultReady(requestId, requester, responseHandler, success, returnData);

        bytes memory message = abi.encodeCall(
            FluentRuntimeGateway.receiveExecutionResult, (requestId, requester, responseHandler, success, returnData)
        );
        FluentBridge bridge = FluentBridge(getBridgeContract());
        uint256 fee = bridge.getSentMessageFee();
        uint256 balance = address(this).balance;
        require(balance >= fee, InsufficientResponseFee(fee, balance));
        bridge.sendMessage{value: fee}(getOtherSideGateway(), message);

        emit FluentRuntimeExecutionResponseSent(requestId, requester, success, keccak256(returnData));
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

        (bool success, bytes memory returnData) = wasmContract.call{value: msg.value}(calldataPayload);

        FluentRuntimeGatewayStorage storage $ = _getFluentRuntimeGatewayStorage();
        require(!$._executionResults[requestId].received, ResultAlreadyReceived(requestId));
        $._executionResults[requestId] = ExecutionResult({
            received: true,
            success: success,
            requester: requester,
            responseHandler: responseHandler,
            responseSent: true,
            returnData: returnData
        });
        emit FluentRuntimeExecutionResultReady(requestId, requester, responseHandler, success, returnData);

        bytes memory message = abi.encodeCall(
            FluentRuntimeGateway.receiveExecutionResult, (requestId, requester, responseHandler, success, returnData)
        );
        FluentBridge bridge = FluentBridge(getBridgeContract());
        uint256 fee = bridge.getSentMessageFee();
        uint256 balance = address(this).balance;
        require(balance >= fee, InsufficientResponseFee(fee, balance));
        bridge.sendMessage{value: fee}(getOtherSideGateway(), message);

        emit FluentRuntimeExecutionResponseSent(requestId, requester, success, keccak256(returnData));
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

        emit FluentRuntimeExecutionResultReceived(requestId, requester, responseHandler, success, returnData);

        if (responseHandler != address(0)) {
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

    function getNextRequestNonce() public view returns (uint256) {
        return _getFluentRuntimeGatewayStorage()._nextRequestNonce;
    }

    function getExecutionResult(bytes32 requestId) public view returns (ExecutionResult memory) {
        return _getFluentRuntimeGatewayStorage()._executionResults[requestId];
    }

    function getBlendFeeConfig()
        public
        view
        returns (
            address blendToken,
            address feeRecipient,
            uint256 deployBaseFee,
            uint256 deployFeePerByte,
            uint256 invokeBaseFee,
            uint256 invokeFeePerByte
        )
    {
        FluentRuntimeGatewayStorage storage $ = _getFluentRuntimeGatewayStorage();
        return
            (
                $._blendToken,
                $._feeRecipient,
                $._deployBaseFee,
                $._deployFeePerByte,
                $._invokeBaseFee,
                $._invokeFeePerByte
            );
    }

    function quoteDeployFee(bytes calldata wasmBytecode, bytes calldata constructorCalldata)
        public
        view
        returns (uint256)
    {
        FluentRuntimeGatewayStorage storage $ = _getFluentRuntimeGatewayStorage();
        return $._deployBaseFee + (wasmBytecode.length + constructorCalldata.length) * $._deployFeePerByte;
    }

    function quoteInvokeFee(bytes calldata calldataPayload) public view returns (uint256) {
        FluentRuntimeGatewayStorage storage $ = _getFluentRuntimeGatewayStorage();
        return $._invokeBaseFee + calldataPayload.length * $._invokeFeePerByte;
    }

    function _requestDeploy(bytes calldata wasmBytecode, bytes calldata constructorCalldata, address responseHandler)
        internal
        returns (bytes32 requestId)
    {
        require(wasmBytecode.length != 0, EmptyWasmBytecode());

        address requester = msg.sender;
        requestId = _takeNextRequestId(requester);
        uint256 blendFee = quoteDeployFee(wasmBytecode, constructorCalldata);
        _chargeBlendFee(requestId, requester, blendFee);
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
        uint256 blendFee = quoteInvokeFee(calldataPayload);
        _chargeBlendFee(requestId, requester, blendFee);
        bytes memory message = abi.encodeCall(
            FluentRuntimeGateway.receiveInvokeRequest,
            (requestId, requester, responseHandler, wasmContract, calldataPayload)
        );
        FluentBridge(getBridgeContract()).sendMessage{value: msg.value}(getOtherSideGateway(), message);

        emit FluentRuntimeInvokeRequested(
            requestId, requester, wasmContract, responseHandler, msg.value, keccak256(calldataPayload)
        );
    }

    function _takeNextRequestId(address requester) internal returns (bytes32 requestId) {
        FluentRuntimeGatewayStorage storage $ = _getFluentRuntimeGatewayStorage();
        uint256 nonce = $._nextRequestNonce++;
        requestId = keccak256(abi.encode(address(this), block.chainid, requester, nonce));
    }

    function _setBlendFeeConfig(
        address blendToken,
        address feeRecipient,
        uint256 deployBaseFee,
        uint256 deployFeePerByte,
        uint256 invokeBaseFee,
        uint256 invokeFeePerByte
    ) internal {
        FluentRuntimeGatewayStorage storage $ = _getFluentRuntimeGatewayStorage();
        $._blendToken = blendToken;
        $._feeRecipient = feeRecipient;
        $._deployBaseFee = deployBaseFee;
        $._deployFeePerByte = deployFeePerByte;
        $._invokeBaseFee = invokeBaseFee;
        $._invokeFeePerByte = invokeFeePerByte;
        emit FluentRuntimeBlendFeeConfigUpdated(
            blendToken, feeRecipient, deployBaseFee, deployFeePerByte, invokeBaseFee, invokeFeePerByte
        );
    }

    function _chargeBlendFee(bytes32 requestId, address requester, uint256 amount) internal {
        if (amount == 0) return;

        FluentRuntimeGatewayStorage storage $ = _getFluentRuntimeGatewayStorage();
        address blendToken = $._blendToken;
        address feeRecipient = $._feeRecipient;
        require(blendToken != address(0) && feeRecipient != address(0), BlendFeeNotConfigured());

        IERC20(blendToken).safeTransferFrom(requester, feeRecipient, amount);
        emit FluentRuntimeBlendFeeCharged(requestId, requester, feeRecipient, amount);
    }

    receive() external payable {}

    function _getFluentRuntimeGatewayStorage() private pure returns (FluentRuntimeGatewayStorage storage $) {
        assembly ("memory-safe") {
            $.slot := FLUENT_RUNTIME_GATEWAY_STORAGE_LOCATION
        }
    }
}
