# Deploying the NFT Gateways (ERC721 + ERC1155)

Runbook for deploying and cross-chain-linking the NFT bridge (ERC721 + ERC1155
factories and gateways). This is **not** covered by `scripts/deploy.sh` — the NFT
bundle is deployed separately with `DeployNFT.s.sol` + `SetupNFT.s.sol`.

> Read this end-to-end before touching mainnet. The risky parts are *decisions*
> (nonce alignment, ownership policy), not the commands themselves.

---

## What gets deployed

`DeployNFT.s.sol` deploys, per chain:

- ERC721: pegged-token impl, factory (UUPS proxy + impl + beacon), gateway (UUPS proxy + impl)
- ERC1155: pegged-token impl, factory (UUPS proxy + impl + beacon), gateway (UUPS proxy + impl)

and wires each factory to its gateway via `setPaymentGateway`.

`SetupNFT.s.sol` links the two chains: `gateway.setOtherSide(...)` on each side,
plus `bridge.registerGateway(...)` and `bridge.setExecuteGasLimit(...)`.

Output manifests: `deployments/<env>/l1.nft.json` and `deployments/<env>/l2.nft.json`.

---

## Access requirements

The account that runs these scripts must satisfy **all three**:

| Action | Script | Requires |
|--------|--------|----------|
| `factory.setPaymentGateway` | DeployNFT | **owner** of the factory (Ownable2Step) |
| `gateway.setOtherSide` | SetupNFT | **owner** of the gateway |
| `bridge.registerGateway` / `setExecuteGasLimit` | SetupNFT | `DEFAULT_ADMIN_ROLE` on the bridge |

Because `setPaymentGateway` is called **inside the deploy tx** by `msg.sender`, the
deployer must own the freshly-deployed contracts. So `INITIAL_OWNER` **must equal the
running account** — do not point it at a different address (see [Mainnet](#mainnet-differences)).

Check bridge admin before starting:

```bash
# DEFAULT_ADMIN_ROLE == bytes32(0)
cast call $BRIDGE "hasRole(bytes32,address)(bool)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 $SENDER \
  --rpc-url $L1_RPC   # repeat for $L2_RPC
```

---

## Cross-chain address matching (the main gotcha)

`SetupNFT` requires the ERC721/ERC1155 **gateway addresses to be identical on L1 and
L2** (`require(local.gateway == remote.gateway)`). Addresses are `CREATE(deployer,
nonce)`, so the deployer's nonce must be **the same on both chains at the start of
`DeployNFT`**.

1. Check both nonces:

   ```bash
   cast nonce $SENDER --rpc-url $L1_RPC
   cast nonce $SENDER --rpc-url $L2_RPC
   ```

2. If they differ, raise the lower one with empty self-transactions until equal
   (send from the chain with the lower nonce; do **not** touch the other chain
   meanwhile):

   ```bash
   for i in $(seq 1 <diff>); do
     cast send $SENDER --value 0 --account $ACCOUNT --rpc-url <lower-chain-rpc>
   done
   ```

3. Pass the aligned value as `EXPECTED_NONCE` to both deploys — the script reverts
   with `unexpected deployer nonce` before broadcasting if it drifted.

> Between the two `DeployNFT` runs, send **no other transactions** from the deployer
> on either chain, or the start nonces diverge again.

---

## `--sender` is required

`--account` only selects the broadcast signer. Inside the script, `msg.sender`
defaults to Foundry's `DefaultSender` (`0x1804…1f38`, nonce 0) unless you pass
`--sender`. The `EXPECTED_NONCE` guard calls `vm.getNonce(msg.sender)`, so without
`--sender` it checks the wrong address and reverts. Always pass both:

```bash
--account $ACCOUNT --sender $SENDER
```

`$SENDER` must be the address `$ACCOUNT` controls (`cast wallet address --account $ACCOUNT`).

---

## Preflight checklist

- [ ] `forge clean && forge build` (OZ upgrade validator needs full build-info)
- [ ] `.env` has `L1_RPC`, `L2_RPC`, and correct `ENV`
- [ ] `cast wallet address --account $ACCOUNT` == `$SENDER`
- [ ] `$SENDER` holds `DEFAULT_ADMIN_ROLE` on **both** bridges
- [ ] `INITIAL_OWNER` == `$SENDER` (owner policy — see Mainnet note)
- [ ] L1 nonce == L2 nonce; record it as `EXPECTED_NONCE`
- [ ] `$SENDER` has gas on both chains

---

## Deploy — testnet

```bash
set -a; source .env; set +a

ACCOUNT=rollupAdmin                                          # cast wallet keystore name
SENDER=0x18fa4399b515f436e213af5e5ad3337ebcb6e717           # address ACCOUNT controls
INITIAL_OWNER=$SENDER
NONCE=44                                                     # aligned L1==L2 nonce

# 1. Deploy NFT bundle on L1 (Sepolia)
NETWORK=testnet/l1 INITIAL_OWNER=$INITIAL_OWNER EXPECTED_NONCE=$NONCE \
  forge script scripts/deploy/DeployNFT.s.sol \
  --rpc-url $L1_RPC --account $ACCOUNT --sender $SENDER --broadcast

# 2. Deploy NFT bundle on L2 (Fluent) — gblend + skip-simulation
NETWORK=testnet/l2 INITIAL_OWNER=$INITIAL_OWNER EXPECTED_NONCE=$NONCE \
  gblend script scripts/deploy/DeployNFT.s.sol \
  --rpc-url $L2_RPC --account $ACCOUNT --sender $SENDER --broadcast --skip-simulation

# 3. Link L1 -> L2
ENV=$ENV LOCAL_NETWORK=l1 REMOTE_NETWORK=l2 \
  forge script scripts/deploy/SetupNFT.s.sol \
  --rpc-url $L1_RPC --account $ACCOUNT --sender $SENDER --broadcast

# 4. Link L2 -> L1
ENV=$ENV LOCAL_NETWORK=l2 REMOTE_NETWORK=l1 \
  gblend script scripts/deploy/SetupNFT.s.sol \
  --rpc-url $L2_RPC --account $ACCOUNT --sender $SENDER --broadcast --skip-simulation
```

`gblend` + `--skip-simulation` on L2: gblend can't simulate proxy delegatecall
(the UUPS `initialize`) locally, so simulation is skipped and errors surface on-chain.

---

## Mainnet differences

Run the exact same four steps with `ENV=mainnet` (config `scripts/config/mainnet/`,
manifests `deployments/mainnet/`), **plus**:

1. **Keys.** Use a hardware signer instead of a keystore: swap `--account $ACCOUNT`
   for `--ledger` / `--trezor`, keep `--sender $SENDER`.

2. **Ownership policy.** On mainnet the canonical owner is the Safe multisig
   (`roles.initialOwner` in `scripts/config/mainnet/*.json`), **not** the deployer.
   But `DeployNFT` needs the deployer to own the contracts at deploy time
   (`setPaymentGateway`) and at setup time (`setOtherSide`). So:

   - Deploy and run setup with `INITIAL_OWNER=$SENDER` (the deployer).
   - **After** setup succeeds, transfer ownership to the Safe. Contracts are
     `Ownable2Step` — transfer is two-step:

     ```bash
     # deployer initiates (per gateway AND per factory, both chains)
     cast send $CONTRACT "transferOwnership(address)" $SAFE \
       --account $ACCOUNT --sender $SENDER --rpc-url <rpc>
     # Safe must then call acceptOwnership() — ownership does NOT move until it does
     ```

   Bridge `registerGateway` / `setExecuteGasLimit` need `DEFAULT_ADMIN_ROLE`; on
   mainnet confirm `$SENDER` holds it (or route those two calls through the Safe /
   timelock — see `MigrateRoles.s.sol` and `docs/DeveloperGuide.md`).

3. **Verify contracts.** Set `VERIFY=1` and `ETHERSCAN_API_KEY` if you want L1
   verification (the manual commands above don't pass `--verify`; add
   `--verify --retries 5 --delay 10` on the L1 steps).

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `unexpected deployer nonce`, `getNonce(...)` shows `0x1804…1f38` nonce 0 | missing `--sender` | add `--sender $SENDER` |
| `unexpected deployer nonce`, real address | nonce drifted between steps | re-check `EXPECTED_NONCE`; realign nonces |
| `ERC721 gateway address mismatch` (in SetupNFT) | L1/L2 nonces weren't equal at deploy | redeploy with aligned nonces |
| revert in `setPaymentGateway` during DeployNFT | `INITIAL_OWNER` != deployer | set `INITIAL_OWNER=$SENDER` |
| revert in `registerGateway` | `$SENDER` lacks `DEFAULT_ADMIN_ROLE` | grant admin or route via Safe |
| gblend fails during simulation | missing flag | add `--skip-simulation` (L2 only) |
