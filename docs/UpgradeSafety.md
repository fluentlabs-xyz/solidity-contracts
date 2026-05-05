# Upgrade Safety

## Current Upgrade Surfaces

- `FluentBridge.sol`: UUPS proxy, authorized by `DEFAULT_ADMIN_ROLE`.
- `ERC20Gateway.sol` and `NativeGateway.sol`: UUPS proxies (via `GatewayBase`), authorized by `owner()`.
- `GenericTokenFactory.sol` descendants: UUPS proxies, authorized by `owner()`.
- `ERC20TokenFactory` beacon: owner can upgrade all deployed `ERC20PeggedToken` proxies through `upgradeTo`.
- `Staking`, `StakingPool`, `SystemReward`, `ChainConfig`, and `SlashingIndicator`: UUPS proxies, authorized by `owner()` through `StakingContext`.
- `Governance`: UUPS proxy, authorized by `owner()`.

## Required Procedure

1. Produce a storage-layout diff before any proxy or beacon upgrade.
2. Deploy the new implementation without broadcasting the upgrade transaction.
3. Run the full test suite, including bridge/gateway and rollup regression tests, against the candidate implementation.
4. Verify initializer and role assumptions remain unchanged. For staking/governance, implementations must keep initializers disabled while proxies initialize through constructor calldata.
5. Broadcast the upgrade from the expected admin account or multisig.
6. Record the implementation address, transaction hash, and storage-layout evidence in the deployment artifacts.

## Unsafe Upgrade Tooling

Some upgrade scripts expose `UNSAFE_SKIP_STORAGE_CHECK` for emergency/operator-controlled flows. Treat those paths as high-risk: use them only with an explicit reason, record the storage-layout evidence separately, and prefer safe OpenZeppelin upgrade validation whenever possible.

## Deployment Checks

- Confirm `otherBridge`, remote gateway, remote factory, and chain ID values before linking stacks.
- Confirm whether the destination uses beacon-based pegged tokens or universal-token deployment.
- For L2 deployments with receive deadlines, confirm `l1BlockOracle` is set and already operational.
- For rollup deployments, confirm verifier addresses, program VKey, genesis hash, and timing windows match the intended environment.
- For staking/governance deployments, confirm immutable constructor dependencies point to the expected proxy addresses before broadcasting.

## Auditor Evidence Checklist

- Storage layout outputs from the build used for deployment.
- Broadcast artifacts for proxy deployment and upgrade transactions.
- Deployment JSON and human-readable address docs updated together.
- Test results covering upgrade guards, role restrictions, and message-path regressions.
