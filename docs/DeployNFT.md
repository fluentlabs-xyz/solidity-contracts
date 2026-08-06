# Deploying the NFT gateways (ERC721 + ERC1155)

Not covered by `scripts/deploy.sh` — the NFT bundle ships separately, with
`DeployNFT.s.sol` + `SetupNFT.s.sol`.

`DeployNFT` does **only** CREATEs — 10 per chain: pegged impl, factory (impl + proxy),
gateway (impl + proxy), for each of ERC721 and ERC1155. Beacons are created by the
factories, so they cost no deployer nonce.

`SetupNFT` does all the wiring: `setPaymentGateway` ×2, `setOtherSide` ×2,
`setBlacklistRegistry` ×2 where the chain has a registry, `registerGateway` ×2. It
either broadcasts the calls (testnet) or writes a Safe batch JSON (mainnet).

---

## Address parity

`SetupNFT` requires the gateway addresses to be **identical on both chains** and refuses
to run otherwise. That comes from `CREATE(deployer, nonce)`: same key, same start nonce,
same sequence — the mechanism every other gateway pair was deployed with.

So: use a **fresh key**, keep its nonce equal on both chains at the start of each run,
and pass the value as `EXPECTED_NONCE`. The script prints the address map before
broadcasting and asserts it afterwards (`nonce map drift` if the CREATE order ever
changes).

The precise rule is that the nonce must be untouched on the chain that **hasn't been
deployed yet**. Transactions on the already-deployed chain are harmless — that's why
bridging gas to L2 from the deployer after the L1 run is fine.

If a run dies halfway: don't patch nonces, fund a new key and redeploy both chains.
Nothing is registered on the bridge until the Safe batch lands, so it costs only gas.

---

## Testnet

The deployer owns everything and holds `DEFAULT_ADMIN_ROLE` on both bridges, so
`SetupNFT` broadcasts directly.

```bash
set -a; source .env; set +a
ACCOUNT=<keystore name>; SENDER=<its address>; NONCE=<aligned L1==L2 nonce>

NETWORK=testnet/l1 INITIAL_OWNER=$SENDER EXPECTED_NONCE=$NONCE \
  forge script scripts/deploy/DeployNFT.s.sol \
  --rpc-url $L1_RPC --account $ACCOUNT --sender $SENDER --broadcast

NETWORK=testnet/l2 INITIAL_OWNER=$SENDER EXPECTED_NONCE=$NONCE \
  forge script scripts/deploy/DeployNFT.s.sol \
  --rpc-url $L2_RPC --account $ACCOUNT --sender $SENDER --broadcast

ENV=testnet LOCAL_NETWORK=l1 REMOTE_NETWORK=l2 \
  forge script scripts/deploy/SetupNFT.s.sol \
  --rpc-url $L1_RPC --account $ACCOUNT --sender $SENDER --broadcast

ENV=testnet LOCAL_NETWORK=l2 REMOTE_NETWORK=l1 \
  forge script scripts/deploy/SetupNFT.s.sol \
  --rpc-url $L2_RPC --account $ACCOUNT --sender $SENDER --broadcast
```

`--sender` is not optional: without it the nonce guard and the address map read
Foundry's default sender instead of your key.

---

## Mainnet

Everything is owned by the Safe (`roles.initialOwner` in `scripts/config/mainnet/*.json`,
4-of-5, same address on both chains); it also holds `DEFAULT_ADMIN_ROLE` on both bridges.
The deployer key owns nothing and only pays gas.

So the bundle is deployed Safe-owned from block zero, and the wiring runs as **two Safe
transactions, one per chain** — the floor, since Safe signatures are bound to a chain id.

**1. Fund the deployer on both chains.** L2 gas is negligible; bridging it over is one
L1 transaction:

```bash
cast send $L1_NATIVE_GATEWAY "sendNativeTokens(address)" $SENDER \
  --value 0.02ether --account $ACCOUNT --rpc-url $L1_RPC
```

**2. Align the nonces.** After a self-funded bridge deposit, L1 is one ahead:

```bash
cast send $SENDER --value 0 --account $ACCOUNT --rpc-url $L2_RPC
cast nonce $SENDER --rpc-url $L1_RPC   # both must match; use this as NONCE
cast nonce $SENDER --rpc-url $L2_RPC
```

**3. Dry run, then deploy.** Without `--broadcast` the script runs against a fork of the
live chain and consumes no nonce — do that on both chains first, then re-run as below.

```bash
NETWORK=mainnet/l1 EXPECTED_NONCE=$NONCE \
  forge script scripts/deploy/DeployNFT.s.sol \
  --rpc-url $L1_RPC --account $ACCOUNT --sender $SENDER --broadcast

NETWORK=mainnet/l2 EXPECTED_NONCE=$NONCE \
  forge script scripts/deploy/DeployNFT.s.sol \
  --rpc-url $L2_RPC --account $ACCOUNT --sender $SENDER --broadcast

diff <(jq -S 'del(.chainId)' deployments/mainnet/l1.nft.json) \
     <(jq -S 'del(.chainId)' deployments/mainnet/l2.nft.json) && echo "addresses match"
```

**4. Build the Safe batches** — no broadcast, no key needed:

```bash
ENV=mainnet LOCAL_NETWORK=l1 REMOTE_NETWORK=l2 SAFE_BATCH=true \
  forge script scripts/deploy/SetupNFT.s.sol --rpc-url $L1_RPC
ENV=mainnet LOCAL_NETWORK=l2 REMOTE_NETWORK=l1 SAFE_BATCH=true \
  forge script scripts/deploy/SetupNFT.s.sol --rpc-url $L2_RPC
```

Before signing, decode the rows and compare them against the manifests —
`cast decode-calldata 'setOtherSide(address,uint256,address,address,address)' <data>`.
`setOtherSide` shows up as "contract interaction" in the Safe UI (the selector isn't in
its signature database), so those two rows are the ones nobody checks by accident.

**5. Execute in the Safe UI.** Per chain: Apps → Transaction Builder → import the
matching JSON → Simulate → sign → execute. The UI wraps the calls into one
`MultiSendCallOnly` delegatecall, so it is one transaction and one signing round. The
import is rejected if the connected chain doesn't match the file's `chainId`.

**6. Verify.**

```bash
ENV=mainnet ./scripts/verify/verify-nft.sh    # source verification, needs ETHERSCAN_API_KEY

cast call $ERC721_FACTORY "paymentGateway()(address)"      --rpc-url <rpc>
cast call $ERC721_GATEWAY "getOtherSideGateway()(address)" --rpc-url <rpc>
cast call $BRIDGE "isGatewayRegistered(address)(bool)" $ERC721_GATEWAY --rpc-url <rpc>
```

Both chains, both standards. Owners must still be the Safe.

---

## Things that will bite

**The batch is atomic and single-use.** `registerGateway` reverts on an already
registered gateway, which fails the whole batch after signatures were collected. If
anything landed between generating and executing, regenerate rather than reuse — the
script drops calls that are already done.

**`executeGasLimit` is bridge-wide and opt-in.** It caps the gas forwarded to *every*
gateway on that bridge, NFT and ERC20 alike, so `SetupNFT` never touches it unless
`SET_EXECUTE_GAS_LIMIT=true`. The first bridge of a collection is the expensive one
(~455k with an IPFS URI, more with a long HTTPS one) against live limits of 550k on L1
and 500k on Fluent. A message that runs out of gas is not stuck: `receiveFailedMessage`
is permissionless and forwards `gasleft()`.

**Blacklist is per-chain.** The registry exists on L1 only, so the L1 batch carries two
`setBlacklistRegistry` calls and the L2 batch doesn't. `BLACKLIST_REGISTRY=0x0` opts out.

**Wiring is what makes it live.** There is no separate enable flag: the moment both
batches execute, anyone can bridge NFTs. The only stop is `pause()` on the bridge, which
stops everything, not just NFTs.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `unexpected deployer nonce`, address `0x1804…1f38` | missing `--sender` |
| `nonce map drift: <label>` | CREATE order changed — don't run the second chain; redeploy both from a fresh key |
| `ERC721 gateway address mismatch` in SetupNFT | nonces weren't equal at deploy; redeploy both |
| `local chain ID mismatch` | `--rpc-url` doesn't match `LOCAL_NETWORK` |
| revert in `setPaymentGateway` / `setOtherSide` | caller isn't the owner — on mainnet these belong in the Safe batch |
| Transaction Builder rejects the import | wrong chain connected |
| `forge` simulation fails on Fluent with something chain-specific | fall back to `gblend script … --broadcast --skip-simulation` |
