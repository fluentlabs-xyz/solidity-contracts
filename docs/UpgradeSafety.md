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

## Upgradeable Contracts and Proxies

### Core Proxy Mechanics

#### 1. Explain how a proxy upgrade works.

A proxy keeps the stable user-facing address and delegates calls to an implementation contract. An upgrade changes the implementation address stored in the proxy's upgrade slot, so future calls execute the new implementation code while continuing to use the proxy's existing storage.

#### 2. Where is the state stored: proxy or implementation?

State is stored in the proxy. Implementation contracts provide code. When the proxy uses `delegatecall`, the implementation code reads and writes the proxy's storage.

#### 3. Why does the implementation constructor not initialize proxy state?

The constructor runs only when the implementation contract itself is deployed. It writes to the implementation's own storage, not the proxy's storage. Calls routed through the proxy never re-run the implementation constructor.

#### 4. Why do upgradeable contracts use `initialize()` instead of constructors?

`initialize()` is called through the proxy, so it writes initialization state into the proxy's storage. Initializers also usually include guards so they can only run once.

#### 5. What is the initializer front-running problem?

If a proxy is deployed without initialization calldata, anyone may be able to call `initialize()` first and become the owner/admin or set privileged configuration. This is why proxies should be initialized atomically during deployment.

#### 6. Why should the implementation contract itself be initialized or disabled?

An uninitialized implementation can sometimes be taken over directly. Even if users should not interact with it, attackers may initialize it, gain roles on the implementation, and exploit implementation-only upgrade paths or selfdestruct/delegatecall patterns. Modern OpenZeppelin implementations call `_disableInitializers()` in the constructor.

#### 7. What is EIP-1967?

EIP-1967 standardizes storage slots for proxy metadata such as implementation, admin, and beacon addresses. This lets tools, explorers, and upgrade libraries reliably inspect proxies without colliding with normal contract storage.

#### 8. Why are implementation/admin slots chosen as `keccak256(...) - 1`?

The slot is derived from a unique string and then decremented by one to avoid collisions with compiler-assigned storage and with possible mappings or arrays derived from the raw hash. It creates a deterministic but practically unreachable storage slot.

#### 9. What is storage collision?

Storage collision happens when proxy metadata and implementation state, or two implementation versions, use the same storage slot for different meanings. An upgrade can then overwrite critical state such as owner, balances, implementation, or admin.

#### 10. What is function selector clashing?

Function selector clashing happens when two functions have the same 4-byte selector. In proxy systems this is dangerous when proxy admin functions and implementation functions collide, because a user call may hit the proxy logic instead of the implementation or vice versa.

### Transparent Proxy

#### 1. What problem does the Transparent Proxy pattern solve?

It separates admin calls from user calls to avoid selector clashing. Non-admin callers are delegated to the implementation. The admin can only perform proxy administration actions.

#### 2. Why can the proxy admin not call implementation functions through the proxy?

If the admin were allowed to fall through to the implementation, admin calls could accidentally execute implementation logic or hit selector collisions. Transparent proxies deliberately block admin fallback to keep admin and user behavior separate.

#### 3. What is `ProxyAdmin`?

`ProxyAdmin` is a management contract, commonly used by OpenZeppelin Transparent proxies, that owns one or more proxies and exposes upgrade/admin operations. Operators interact with `ProxyAdmin` rather than each proxy directly.

#### 4. What can go wrong if the admin is an EOA?

An EOA admin can accidentally call the proxy expecting application behavior and instead hit admin-only proxy behavior. It also creates key-management risk: compromise or loss of the EOA can compromise or freeze upgrades.

#### 5. Why is Transparent Proxy more expensive than UUPS?

Transparent proxies keep upgrade/admin logic in the proxy and perform an admin-vs-user branch on calls. UUPS proxies are thinner: upgrade logic lives in the implementation, so normal calls through the proxy have less proxy-side logic.

### UUPS

#### 1. How does UUPS differ from Transparent Proxy?

In UUPS, the proxy is minimal and stores the implementation address, while the implementation contains the upgrade function. In Transparent proxies, the proxy itself contains upgrade/admin logic.

#### 2. Where does upgrade logic live in UUPS?

Upgrade logic lives in the implementation contract, usually by inheriting `UUPSUpgradeable`. The proxy delegates the upgrade call to the implementation, which writes the new implementation address into the proxy's EIP-1967 slot.

#### 3. What is `_authorizeUpgrade()`?

`_authorizeUpgrade()` is the access-control hook that decides who may upgrade a UUPS proxy. Implementations must override it with ownership, role, governance, or timelock checks.

#### 4. What happens if you upgrade to an implementation without UUPS upgrade logic?

The proxy may still delegate normal calls, but future upgrades can be bricked because the new implementation does not expose the UUPS upgrade functions needed to change the implementation again.

#### 5. What is `proxiableUUID()`?

`proxiableUUID()` returns the storage slot that the implementation expects to use for the implementation address. UUPS upgrade logic checks it to ensure the new implementation is compatible with the proxy's upgrade slot.

#### 6. Why is mixing UUPS implementations with Transparent proxies dangerous?

A UUPS implementation exposes upgrade logic in the implementation. If used behind a Transparent proxy incorrectly, non-admin users may be able to call the implementation's UUPS upgrade function through the proxy if `_authorizeUpgrade()` permits them, bypassing Transparent proxy admin expectations.

#### 7. How can an attacker take over an uninitialized UUPS implementation?

If the implementation itself is not initialized or disabled, an attacker can call `initialize()` on the implementation contract directly and become its owner. In older UUPS patterns, that owner could then call implementation upgrade functions or exploit delegatecall-based upgrade checks.

#### 8. Why did the old UUPS bricking vulnerability happen?

Older UUPS implementations could be initialized directly and then upgraded in the implementation's own context to malicious code that selfdestructed or otherwise broke upgrade behavior. Since proxies delegate to implementation code, destroying or corrupting the implementation could brick all proxies pointing to it.

#### 9. How do you test UUPS upgrade safety?

Test that only authorized accounts can upgrade, unauthorized accounts revert, the new implementation passes `proxiableUUID()` checks, storage layout remains compatible, state survives the upgrade, initializer/reinitializer paths cannot be abused, and upgrading to a non-UUPS implementation is rejected.

### Beacon Proxy

#### 1. What is a Beacon Proxy?

A Beacon Proxy delegates to the implementation returned by a separate beacon contract. The proxy stores the beacon address, and the beacon stores the current implementation address.

#### 2. Why use Beacon proxies for factories?

Factories often deploy many identical instances. Beacon proxies let all instances share one upgrade point: upgrading the beacon upgrades every proxy that reads from it.

#### 3. What is the blast radius of a Beacon upgrade?

The blast radius is every proxy connected to that beacon. A bad beacon implementation upgrade can break or compromise all deployed instances at once.

#### 4. How do you validate a beacon implementation?

Check that the new implementation has code, supports the expected interface, is storage-compatible with existing proxies, has initializers disabled if needed, does not rely on constructor state, and passes functional regression tests against existing proxy state.

#### 5. What happens if the beacon returns an EOA address?

Calls through the proxy delegate to an address with no code. Depending on proxy implementation, calls will fail or return empty data, effectively bricking the beacon proxies until the beacon is corrected.

#### 6. What checks should ReleaseValidator perform before beacon upgrades?

It should check that the beacon address has code, the new implementation has code, the caller is authorized, the implementation is compatible with the expected token/validator interface, storage layout is safe, and the upgrade is not stale relative to the proposal/timelock state.

### Upgrade Governance

#### 1. Why is upgrade execution a state machine?

An upgrade moves through phases: proposal, validation, voting/approval, timelock, execution, cancellation, rejection, or expiry. Each phase has different permissions and invariants, so treating it as a state machine prevents invalid transitions.

#### 2. What is the difference between submit-time validation and execution-time validation?

Submit-time validation checks a proposal when it is created. Execution-time validation checks again when the upgrade actually executes. Conditions can change during voting or timelock, so execution-time checks are mandatory.

#### 3. Why should upgrade payloads be revalidated after timelock?

During the timelock, roles, code at target addresses, proxy admin ownership, beacon implementations, chain configuration, or dependencies may change. Revalidation prevents executing a payload that was safe when submitted but unsafe later.

#### 4. How can a rejected proposal brick a nonce-ordered governance system?

If proposals must execute strictly by nonce and a rejected proposal leaves the nonce stuck, all later proposals may be blocked forever. Rejection must advance, skip, or otherwise resolve the nonce.

#### 5. Should proposal rejection consume a nonce?

Usually yes. Rejection should finalize that proposal slot so the system can progress. If rejection does not consume or explicitly skip the nonce, nonce-ordered execution can be bricked.

#### 6. How do you handle role membership changes during timelock?

Recheck role membership at execution time. Decide explicitly whether the proposal uses the submit-time voter/admin set or the execution-time set, and encode that policy in the state machine.

#### 7. How should upgrade multisig support vote switching?

Vote switching should update the stored vote weight or approval state instead of double-counting. The system should subtract the old vote, add the new vote, emit the change, and preserve quorum/threshold invariants.

#### 8. What is stale validation?

Stale validation is relying on a check that was true earlier but may no longer be true. For upgrades, examples include target code existing at submit time but being changed later, or a caller having a role at approval time but losing it before execution.

#### 9. Why should upgrade target `code.length > 0` be checked?

Upgrading to an address without code bricks calls through the proxy or beacon. Checking `code.length > 0` catches EOAs, undeployed CREATE2 addresses, destroyed contracts, and wrong network addresses.

#### 10. How do you design a safe emergency rollback?

Pre-approve known-good rollback implementations, preserve storage compatibility, route rollback through the same authorization path or a narrowly scoped emergency role, revalidate target code at execution, emit clear events, and test rollback from realistic broken states. Emergency rollback should be fast, but not an unbounded arbitrary upgrade bypass.
