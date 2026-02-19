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

const L1_RPC = process.env.L1_RPC_URL || "https://rpc.sepolia.org";
const L2_RPC = process.env.L2_RPC_URL || "https://rpc.dev.fluent.xyz";
const L1_BRIDGE = process.env.L1_BRIDGE_ADDRESS;
const L2_BRIDGE = process.env.L2_BRIDGE_ADDRESS;
const RELAYER_PK = process.env.RELAYER_PRIVATE_KEY;

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

async function main() {
    requireEnv("L1_BRIDGE_ADDRESS", L1_BRIDGE);
    requireEnv("L2_BRIDGE_ADDRESS", L2_BRIDGE);
    requireEnv("RELAYER_PRIVATE_KEY", RELAYER_PK);

    const l1Provider = new ethers.JsonRpcProvider(L1_RPC);
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

    // L1 SentMessage → queue for L2 (to = L2 gateway, so message is for L2)
    l1Bridge.on(l1Bridge.filters.SentMessage(), (sender, to, value, chainId, blockNumber, nonce, messageHash, data) => {
        toL2Queue.push({ sender, to, value, chainId, blockNumber, nonce, data });
        toL2Queue.sort((a, b) => {
            const c = Number(a.blockNumber) - Number(b.blockNumber);
            return c !== 0 ? c : Number(a.nonce) - Number(b.nonce);
        });
        relayToL2();
    });

    // L2 SentMessage → queue for L1
    l2Bridge.on(l2Bridge.filters.SentMessage(), (sender, to, value, chainId, blockNumber, nonce, messageHash, data) => {
        toL1Queue.push({ sender, to, value, chainId, blockNumber, nonce, data });
        toL1Queue.sort((a, b) => {
            const c = Number(a.blockNumber) - Number(b.blockNumber);
            return c !== 0 ? c : Number(a.nonce) - Number(b.nonce);
        });
        relayToL1();
    });

    // Backfill: fetch recent SentMessage and enqueue (order by blockNumber, nonce)
    async function backfill(bridge, queue, isL1) {
        const filter = bridge.filters.SentMessage();
        const name = isL1 ? "L1" : "L2";
        const destName = isL1 ? "L2" : "L1";
        const toBlock = await bridge.runner.provider.getBlockNumber();
        const fromBlock = Math.max(0, toBlock - 2000);
        const events = await bridge.queryFilter(filter, fromBlock, toBlock);
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
        queue.sort((a, b) => {
            const c = Number(a.blockNumber) - Number(b.blockNumber);
            return c !== 0 ? c : Number(a.nonce) - Number(b.nonce);
        });
        if (queue.length) console.log(`[${name}→${destName}] backfill ${queue.length} messages`);
    }

    await backfill(l1Bridge, toL2Queue, true);
    await backfill(l2Bridge, toL1Queue, false);
    relayToL2();
    relayToL1();

    console.log("Relayer running. L1 bridge:", L1_BRIDGE, "L2 bridge:", L2_BRIDGE);
    console.log("Relayer address:", relayer.address);
}

main().catch(err => {
    console.error(err);
    process.exit(1);
});
