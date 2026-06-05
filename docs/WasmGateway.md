# WasmGateway

`WasmGateway` forwards Ethereum-originated Fluent Runtime WASM deployment and invocation requests through the existing `FluentBridge` message lifecycle.

## Flow

1. Source user calls `requestDeploy(wasmBytecode, constructorCalldata)` or `requestInvoke(wasmContract, calldataPayload)` and supplies native value for the destination runtime fee.
2. The gateway calls `FluentBridge.sendMessage{value: msg.value}(otherSideGateway, payload)`.
3. The relayer delivers the bridge message to the destination gateway.
4. The destination gateway verifies `getNativeSender() == otherSideGateway`, then calls the configured `IFluentWasmRuntime` endpoint.
5. If the runtime call reverts, bridge delivery records the message as `Failed`; callers can use the existing `receiveFailedMessage` retry path after fixing runtime/gateway configuration.

## Runtime Interface

```solidity
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
```

The source-chain gateway may use `runtime = address(0)`. The destination-chain gateway must have a non-zero runtime before receiving messages, or delivery fails with `RuntimeNotConfigured`.

## Deployment Notes

Deploy with `scripts/deploy/DeployWasmGateway.s.sol`.

Required environment:

- `INITIAL_OWNER`
- `BRIDGE_ADDRESS`

Optional environment:

- `RUNTIME_ADDRESS`
- `OUTPUT_PATH`

After deployment, register both local and remote gateway addresses on their local `FluentBridge` instances, and call `setOtherSideGateway(remoteGateway)` on each gateway.
