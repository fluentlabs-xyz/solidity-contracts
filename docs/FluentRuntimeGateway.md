# FluentRuntimeGateway

`FluentRuntimeGateway` forwards Ethereum-originated Fluent Runtime deployment and invocation requests through the existing `FluentBridge` message lifecycle.

## Flow

1. Source user calls `requestDeploy(wasmBytecode, constructorCalldata)` or `requestInvoke(wasmContract, calldataPayload)` and supplies native value for the destination runtime fee. The gateway returns and emits a `requestId`.
2. If the user wants a callback on the source chain, they call `requestDeployWithHandler(...)` or `requestInvokeWithHandler(...)` with a contract that implements `IFluentRuntimeResponseHandler`.
3. The gateway calls `FluentBridge.sendMessage{value: msg.value}(otherSideGateway, payload)`.
4. The relayer delivers the bridge message to the destination gateway.
5. The destination gateway verifies `getNativeSender() == otherSideGateway`, then calls the configured `IFluentRuntime` endpoint.
6. The destination gateway stores `ExecutionResult` under `requestId` and emits `FluentRuntimeExecutionResultReady`. Runtime reverts are stored as `success = false` with the revert data; they do not make the bridge delivery fail.
7. Anyone can call `sendExecutionResult(requestId)` on the destination gateway, paying the local bridge fee if one is configured. This sends the stored result back to the source gateway.
8. The source gateway stores the returned result under the same `requestId` and emits `FluentRuntimeExecutionResultReceived`. Users can manually verify the result with `getExecutionResult(requestId)`.
9. If a response handler was provided, the source gateway calls `handleFluentRuntimeResult(requestId, requester, success, returnData)` after storing the result.

## Runtime Interface

```solidity
interface IFluentRuntime {
    function deployWasm(address requester, bytes calldata wasmBytecode, bytes calldata constructorCalldata)
        external
        payable
        returns (address contractAddress);

    function invokeWasm(address requester, address wasmContract, bytes calldata calldataPayload)
        external
        payable
        returns (bytes memory returnData);
}

interface IFluentRuntimeResponseHandler {
    function handleFluentRuntimeResult(bytes32 requestId, address requester, bool success, bytes calldata returnData)
        external;
}
```

The source-chain gateway may use `runtime = address(0)`. If the destination-chain gateway has no runtime configured, it records a failed result with `RuntimeNotConfigured` encoded in `returnData`.

## Deployment Notes

Deploy with `scripts/deploy/DeployFluentRuntimeGateway.s.sol`.

Required environment:

- `INITIAL_OWNER`
- `BRIDGE_ADDRESS`

Optional environment:

- `RUNTIME_ADDRESS`
- `OUTPUT_PATH`

After deployment, register both local and remote gateway addresses on their local `FluentBridge` instances, and call `setOtherSideGateway(remoteGateway)` on each gateway.
