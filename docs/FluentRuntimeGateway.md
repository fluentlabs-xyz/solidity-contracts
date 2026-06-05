# FluentRuntimeGateway

`FluentRuntimeGateway` forwards Ethereum-originated Fluent Runtime deployment and invocation requests through the existing `FluentBridge` message lifecycle.

## Flow

1. Source user calls `requestDeploy(wasmBytecode, constructorCalldata)` or `requestInvoke(wasmContract, calldataPayload)` and supplies native value for the destination execution fee. The gateway returns and emits a `requestId`.
2. If the user wants a callback on the source chain, they call `requestDeployWithHandler(...)` or `requestInvokeWithHandler(...)` with a contract that implements `IFluentRuntimeResponseHandler`.
3. The gateway calls `FluentBridge.sendMessage{value: msg.value}(otherSideGateway, payload)`.
4. The relayer delivers the bridge message to the destination gateway.
5. The destination gateway verifies `getNativeSender() == otherSideGateway`, then handles execution on L2 directly:
   - deploy requests use native `CREATE` with `wasmBytecode || constructorCalldata` as init code;
   - invoke requests call `wasmContract` with `calldataPayload`.
6. The destination gateway stores `ExecutionResult` under `requestId` and emits `FluentRuntimeExecutionResultReady`. WASM call reverts are stored as `success = false` with the revert data; native deploy failures are stored with `NativeWasmDeployFailed`; neither case makes the bridge delivery fail.
7. Anyone can call `sendExecutionResult(requestId)` on the destination gateway, paying the local bridge fee if one is configured. This sends the stored result back to the source gateway.
8. The source gateway stores the returned result under the same `requestId` and emits `FluentRuntimeExecutionResultReceived`. Users can manually verify the result with `getExecutionResult(requestId)`.
9. If a response handler was provided, the source gateway calls `handleFluentRuntimeResult(requestId, requester, success, returnData)` after storing the result.

## Response Handler Interface

```solidity
interface IFluentRuntimeResponseHandler {
    function handleFluentRuntimeResult(bytes32 requestId, address requester, bool success, bytes calldata returnData)
        external;
}
```

Deploy responses encode the created contract address as `abi.encode(address)`. Invoke responses store the direct return data from the called WASM contract.

## Deployment Notes

Deploy with `scripts/deploy/DeployFluentRuntimeGateway.s.sol`.

Required environment:

- `INITIAL_OWNER`
- `BRIDGE_ADDRESS`

Optional environment:

- `OUTPUT_PATH`

The deployment script registers the newly deployed local gateway on the provided `FluentBridge`. After both sides are deployed, also register each remote gateway address on the opposite local `FluentBridge` if needed by the environment, and call `setOtherSideGateway(remoteGateway)` on each gateway.
