import { Contract, Interface, JsonRpcProvider, TransactionRequest, Wallet, toUtf8Bytes } from "ethers";
import * as cKzg from "c-kzg";
import { Kzg } from "ethers";
import * as fs from "fs";
import * as path from "path";

/**
 * Types that mirror Rollup.sol
 */
type BlockCommitment = {
    previousBlockHash: string;
    blockHash: string;
    withdrawalHash: string;
    depositHash: string;
};

type DepositsInBlock = {
    blockHash: string;
    depositCount: bigint | number;
};

// Must match Rollup.ZERO_BYTES_HASH
const ZERO_HASH = "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";

/**
 * Max bytes of data that can fit into a single blob.
 * EIP-4844 specifies 4096 field elements of 32 bytes each.
 */
const MAX_BLOB_BYTES = 4096 * 32; // 131072 bytes

/**
 * Split an arbitrary byte array into multiple blob-sized chunks.
 * This is how we handle the case when all txs do not fit into a single blob.
 */
function chunkToBlobPayloads(data: Uint8Array, maxBytesPerBlob = MAX_BLOB_BYTES): Uint8Array[] {
    const chunks: Uint8Array[] = [];
    for (let offset = 0; offset < data.length; offset += maxBytesPerBlob) {
        const end = Math.min(offset + maxBytesPerBlob, data.length);
        chunks.push(data.slice(offset, end));
    }
    return chunks;
}

/**
 * Build the opaque payload that will go into blobs.
 *
 * In production you should:
 * - Encode per-block tx lists as an RLP array
 * - Compress the RLP bytes with brotli
 *
 * Here we keep it simple and just JSON-encode for illustration. Replace with
 * your real encoding when wiring in the prover.
 */
function buildBatchBlobPayload(allBlockTxs: unknown[]): Uint8Array {
    const json = JSON.stringify(allBlockTxs);
    return toUtf8Bytes(json);
}

/**
 * Initialize KZG context from a trusted setup JSON file.
 *
 * Expects env KZG_TRUSTED_SETUP to point to a JSON file compatible with c-kzg.
 */
function initKzgFromEnv(): Kzg {
    const setupPath = process.env.KZG_TRUSTED_SETUP;
    if (!setupPath) {
        throw new Error("KZG_TRUSTED_SETUP env var not set (path to trusted setup JSON)");
    }

    const resolved = path.resolve(setupPath);
    const json = JSON.parse(fs.readFileSync(resolved, "utf8"));
    return new Kzg(cKzg, json);
}

async function main() {
    const rpcUrl = process.env.FLUENT_RPC;
    const l2RpcUrl = process.env.FLUENT_L2_RPC || rpcUrl;
    const sequencerKey = process.env.SEQUENCER_PRIVATE_KEY;
    const rollupAddress = process.env.ROLLUP_ADDRESS;

    if (!rpcUrl) throw new Error("FLUENT_RPC env var not set");
    if (!sequencerKey) throw new Error("SEQUENCER_PRIVATE_KEY env var not set");
    if (!rollupAddress) throw new Error("ROLLUP_ADDRESS env var not set");

    const provider = new JsonRpcProvider(rpcUrl);
    const l2Provider = new JsonRpcProvider(l2RpcUrl);
    const wallet = new Wallet(sequencerKey, provider);
    const kzg = initKzgFromEnv();

    // ---------------------------------------------------------------------
    // 1. Load rollup config (batch size, next batch index, previous batch hash)
    // ---------------------------------------------------------------------

    const rollup = new Contract(
        rollupAddress,
        [
            "function batchSize() view returns (uint256)",
            "function nextBatchIndex() view returns (uint256)",
            "function lastBlockHashInBatch(uint256) view returns (bytes32)"
        ],
        wallet
    );

    const batchSize: number = Number(await rollup.batchSize());
    const nextBatchIndex: bigint = await rollup.nextBatchIndex();
    const batchIndex = nextBatchIndex;

    const prevBatchIndex = nextBatchIndex === 0n ? 0n : nextBatchIndex - 1n;
    const prevLastHash: string = await rollup.lastBlockHashInBatch(prevBatchIndex);

    console.log(`Using batchSize=${batchSize}, nextBatchIndex=${nextBatchIndex.toString()}`);
    console.log(`Previous batch last block hash: ${prevLastHash}`);

    const commitments: BlockCommitment[] = [];

    // Example: no deposits in this batch; adapt as needed.
    const depositsInBlocks: DepositsInBlock[] = [];

    // ---------------------------------------------------------------------
    // 2. Fetch real Fluent L2 blocks and build commitments + blob payload(s)
    // ---------------------------------------------------------------------

    // Choose which L2 blocks to include.
    // If BATCH_START_BLOCK is provided, use that as the first block; otherwise use latest - batchSize + 1.
    const batchStartEnv = process.env.BATCH_START_BLOCK;
    const latestL2 = await l2Provider.getBlockNumber();
    let startBlock =
        batchStartEnv !== undefined ? Number(batchStartEnv) : Math.max(0, latestL2 - batchSize + 1);

    console.log(`Building batch from L2 blocks [${startBlock}, ${startBlock + batchSize - 1}]`);

    const allBlockTxs: unknown[] = [];

    for (let i = 0; i < batchSize; i++) {
        const blockNumber = startBlock + i;
        const block = await l2Provider.getBlock(blockNumber, true);
        if (!block) {
            throw new Error(`Failed to fetch L2 block ${blockNumber}`);
        }
        if (!block.hash) {
            throw new Error(`L2 block ${blockNumber} has no hash`);
        }

        const previousBlockHash =
            i === 0 ? prevLastHash : commitments[i - 1].blockHash;

        commitments.push({
            previousBlockHash,
            blockHash: block.hash,
            // Until you wire real withdrawal/deposit roots, use ZERO_HASH so Rollup skips checks.
            withdrawalHash: ZERO_HASH,
            depositHash: ZERO_HASH
        });

        allBlockTxs.push({
            blockNumber: block.number,
            hash: block.hash,
            parentHash: block.parentHash,
            txs: block.transactions.map((tx: any) => (typeof tx === "string" ? tx : tx.hash))
        });
    }

    const batchPayload = buildBatchBlobPayload(allBlockTxs);
    const blobs = chunkToBlobPayloads(batchPayload);
    const numBlobs = blobs.length;

    console.log(`Prepared batch payload of ${batchPayload.length} bytes into ${numBlobs} blob(s).`);

    // ---------------------------------------------------------------------
    // 3. Encode Rollup.acceptNextBatch(...) calldata
    // ---------------------------------------------------------------------

    const rollupAbi = [
        "function acceptNextBatch(uint256 _batchIndex,(bytes32 previousBlockHash,bytes32 blockHash,bytes32 withdrawalHash,bytes32 depositHash)[] _commitmentBatch,(bytes32 blockHash,uint256 depositCount)[] depositsInBlocks,uint256 _numBlobs) external payable"
    ];

    const rollupInterface = new Interface(rollupAbi);

    const data = rollupInterface.encodeFunctionData("acceptNextBatch", [
        batchIndex,
        commitments,
        depositsInBlocks,
        BigInt(numBlobs)
    ]);

    // ---------------------------------------------------------------------
    // 4. Build and send the blob transaction
    // ---------------------------------------------------------------------

    const txRequest: TransactionRequest = {
        to: rollupAddress,
        data,
        // EIP-4844 fields
        blobs,
        kzg
    };

    console.log("Sending acceptNextBatch transaction with blobs...");
    const txResponse = await wallet.sendTransaction(txRequest);
    console.log(`Submitted tx: ${txResponse.hash}`);
    const receipt = await txResponse.wait();
    console.log(`Mined in block ${receipt.blockNumber}`);
}

if (require.main === module) {
    // eslint-disable-next-line @typescript-eslint/no-floating-promises
    main().catch((err) => {
        console.error(err);
        process.exit(1);
    });
}

