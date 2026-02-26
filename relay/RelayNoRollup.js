/**
 * No-Rollup Bridge Relayer
 *
 * Watches SentMessage on both chains and calls receiveMessage on the other chain.
 * No sequencer or Rollup needed. Requires:
 *   - Both bridges deployed with rollup = address(0)
 *   - RELAYER_PRIVATE_KEY is bridgeAuthority on both bridges
 *
 * Env:
 *   L1_RPC_URL, L2_RPC_URL
 *   L1_BRIDGE_ADDRESS, L2_BRIDGE_ADDRESS
 *   RELAYER_PRIVATE_KEY  (must be bridgeAuthority on both)
 *
 * Run: node relay/RelayNoRollup.js
 */

const { ethers } = require("ethers");

const L1_RPC_DEFAULT = process.env.L1_RPC_URL || process.env.RPC_URL_SEPOLIA_ETH || "https://ethereum-sepolia-rpc.publicnode.com";
const L1_RPC_FALLBACKS = ["https://sepolia.drpc.org", "https://rpc2.sepolia.org"];
const L2_RPC = process.env.L2_RPC_URL || process.env.RPC_URL_FLUENT_DEV || "https://rpc.dev.fluent.xyz";
const L1_BRIDGE = process.env.L1_BRIDGE_ADDRESS;
const L2_BRIDGE = process.env.L2_BRIDGE_ADDRESS;
const RELAYER_PK = process.env.RELAYER_PRIVATE_KEY || process.env.PRIVATE_KEY;
const BACKFILL_BLOCKS = Number(process.env.BACKFILL_BLOCKS || "2000");
const L1_BACKFILL_FROM_BLOCK = process.env.L1_BACKFILL_FROM_BLOCK ? Number(process.env.L1_BACKFILL_FROM_BLOCK) : null;
const L2_BACKFILL_FROM_BLOCK = process.env.L2_BACKFILL_FROM_BLOCK ? Number(process.env.L2_BACKFILL_FROM_BLOCK) : null;
const MAX_BACKFILL_QUERY_RANGE = Number(process.env.MAX_BACKFILL_QUERY_RANGE || "9000");

const BRIDGE_ABI = [
    "event SentMessage(address indexed sender, address indexed to, uint256 value, uint256 chainId, uint256 blockNumber, uint256 nonce, bytes32 messageHash, bytes data)",
    "function receiveMessage(address _from, address _to, uint256 _value, uint256 _chainId, uint256 _blockNumber, uint256 _nonce, bytes calldata _message) external payable",
    "function receivedNonce() external view returns (uint256)",
];

function requireEnv(name, value) {
    if (!value) {
        console.error(`Missing env: ${name}`);
        process.exit(1);
    }
    return value;
}

async function connectL1Provider() {
    const urls = [L1_RPC_DEFAULT, ...L1_RPC_FALLBACKS];
    for (const url of urls) {
        try {
            const provider = new ethers.JsonRpcProvider(url);
            await provider.getNetwork();
            return provider;
        } catch (e) {
            continue;
        }
    }
    throw new Error("All L1 RPC URLs failed. Set L1_RPC_URL or RPC_URL_SEPOLIA_ETH in .env to a working Sepolia RPC.");
}

async function main() {
    requireEnv("L1_BRIDGE_ADDRESS", L1_BRIDGE);
    requireEnv("L2_BRIDGE_ADDRESS", L2_BRIDGE);
    requireEnv("RELAYER_PRIVATE_KEY", RELAYER_PK);

    const l1Provider = await connectL1Provider();
    const l2Provider = new ethers.JsonRpcProvider(L2_RPC);
    const relayer = new ethers.Wallet(RELAYER_PK);
    const l1Signer = relayer.connect(l1Provider);
    const l2Signer = relayer.connect(l2Provider);

    const l1Bridge = new ethers.Contract(L1_BRIDGE, BRIDGE_ABI, l1Signer);
    const l2Bridge = new ethers.Contract(L2_BRIDGE, BRIDGE_ABI, l2Signer);

    const l1ChainId = (await l1Provider.getNetwork()).chainId;
    const l2ChainId = (await l2Provider.getNetwork()).chainId;

    // Queues: messages from source chain to relay in order (by blockNumber, nonce)
    const toL2Queue = [];
    const toL1Queue = [];
    let relayingToL2 = false;
    let relayingToL1 = false;

    async function relayToL2() {
        if (relayingToL2 || toL2Queue.length === 0) return;
        relayingToL2 = true;
        const next = toL2Queue[0];
        try {
            const expectedNonce = await l2Bridge.receivedNonce();
            const tx = await l2Bridge.receiveMessage(
                next.sender,
                next.to,
                next.value,
                next.chainId,
                next.blockNumber,
                expectedNonce,
                next.data,
                { gasLimit: 500_000 }
            );
            await tx.wait();
            toL2Queue.shift();
            console.log("[L1→L2] relayed srcNonce", next.nonce.toString(), "tx", tx.hash);
        } catch (e) {
            if (e.message && (e.message.includes("MessageAlreadyReceived") || e.message.includes("MessageReceivedOutOfOrder"))) {
                toL2Queue.shift();
                if (toL2Queue.length > 0) setTimeout(relayToL2, 500);
            } else {
                console.error("[L1→L2] relay failed:", e.message);
            }
        }
        relayingToL2 = false;
        if (toL2Queue.length > 0) setTimeout(relayToL2, 1000);
    }

    async function relayToL1() {
        if (relayingToL1 || toL1Queue.length === 0) return;
        relayingToL1 = true;
        const next = toL1Queue[0];
        try {
            const expectedNonce = await l1Bridge.receivedNonce();
            const tx = await l1Bridge.receiveMessage(
                next.sender,
                next.to,
                next.value,
                next.chainId,
                next.blockNumber,
                expectedNonce,
                next.data,
                { gasLimit: 500_000 }
            );
            await tx.wait();
            toL1Queue.shift();
            console.log("[L2→L1] relayed srcNonce", next.nonce.toString(), "tx", tx.hash);
        } catch (e) {
            if (e.message && (e.message.includes("MessageAlreadyReceived") || e.message.includes("MessageReceivedOutOfOrder"))) {
                toL1Queue.shift();
                if (toL1Queue.length > 0) setTimeout(relayToL1, 500);
            } else {
                console.error("[L2→L1] relay failed:", e.message);
            }
        }
        relayingToL1 = false;
        if (toL1Queue.length > 0) setTimeout(relayToL1, 1000);
    }

    // Poll for new SentMessage instead of .on() filters (avoids "filter not found" on public RPCs)
    const POLL_INTERVAL_MS = 15_000;
    let lastL1Block = await l1Provider.getBlockNumber();
    let lastL2Block = await l2Provider.getBlockNumber();

    function enqueueL1Event(args) {
        toL2Queue.push({
            sender: args.sender,
            to: args.to,
            value: args.value,
            chainId: args.chainId,
            blockNumber: args.blockNumber,
            nonce: args.nonce,
            data: args.data,
        });
        toL2Queue.sort((a, b) => {
            const c = Number(a.blockNumber) - Number(b.blockNumber);
            return c !== 0 ? c : Number(a.nonce) - Number(b.nonce);
        });
        relayToL2();
    }

    function enqueueL2Event(args) {
        toL1Queue.push({
            sender: args.sender,
            to: args.to,
            value: args.value,
            chainId: args.chainId,
            blockNumber: args.blockNumber,
            nonce: args.nonce,
            data: args.data,
        });
        toL1Queue.sort((a, b) => {
            const c = Number(a.blockNumber) - Number(b.blockNumber);
            return c !== 0 ? c : Number(a.nonce) - Number(b.nonce);
        });
        relayToL1();
    }

    async function pollL1() {
        try {
            const toBlock = await l1Provider.getBlockNumber();
            if (toBlock <= lastL1Block) return;
            const events = await l1Bridge.queryFilter(l1Bridge.filters.SentMessage(), lastL1Block + 1, toBlock);
            for (const e of events) enqueueL1Event(e.args);
            lastL1Block = toBlock;
        } catch (e) {
            console.error("[L1 poll]", e.message || e);
        }
        setTimeout(pollL1, POLL_INTERVAL_MS);
    }

    async function pollL2() {
        try {
            const toBlock = await l2Provider.getBlockNumber();
            if (toBlock <= lastL2Block) return;
            const events = await l2Bridge.queryFilter(l2Bridge.filters.SentMessage(), lastL2Block + 1, toBlock);
            for (const e of events) enqueueL2Event(e.args);
            lastL2Block = toBlock;
        } catch (e) {
            console.error("[L2 poll]", e.message || e);
        }
        setTimeout(pollL2, POLL_INTERVAL_MS);
    }

    setTimeout(pollL1, POLL_INTERVAL_MS);
    setTimeout(pollL2, POLL_INTERVAL_MS);

    // Backfill: fetch recent SentMessage and enqueue (order by blockNumber, nonce)
    async function backfill(bridge, queue, isL1) {
        const filter = bridge.filters.SentMessage();
        const name = isL1 ? "L1" : "L2";
        const destName = isL1 ? "L2" : "L1";
        const toBlock = await bridge.runner.provider.getBlockNumber();
        const explicitFrom = isL1 ? L1_BACKFILL_FROM_BLOCK : L2_BACKFILL_FROM_BLOCK;
        const fromBlock = explicitFrom !== null ? explicitFrom : Math.max(0, toBlock - BACKFILL_BLOCKS);
        // Query in chunks to avoid free-tier RPC limits on eth_getLogs range.
        for (let start = fromBlock; start <= toBlock; start += MAX_BACKFILL_QUERY_RANGE + 1) {
            const end = Math.min(toBlock, start + MAX_BACKFILL_QUERY_RANGE);
            const events = await bridge.queryFilter(filter, start, end);
            for (const e of events) {
                const args = e.args;
                queue.push({
                    sender: args.sender,
                    to: args.to,
                    value: args.value,
                    chainId: args.chainId,
                    blockNumber: args.blockNumber,
                    nonce: args.nonce,
                    data: args.data,
                });
            }
        }
        queue.sort((a, b) => {
            const c = Number(a.blockNumber) - Number(b.blockNumber);
            return c !== 0 ? c : Number(a.nonce) - Number(b.nonce);
        });
        if (queue.length) console.log(`[${name}→${destName}] backfill ${queue.length} messages (blocks ${fromBlock}-${toBlock})`);
        return toBlock;
    }

    lastL1Block = await backfill(l1Bridge, toL2Queue, true);
    lastL2Block = await backfill(l2Bridge, toL1Queue, false);
    relayToL2();
    relayToL1();

    console.log("Relayer running (poll every", POLL_INTERVAL_MS / 1000, "s). L1 bridge:", L1_BRIDGE, "L2 bridge:", L2_BRIDGE);
    console.log("Relayer address:", relayer.address);
}

main().catch(err => {
    console.error(err);
    process.exit(1);
});
