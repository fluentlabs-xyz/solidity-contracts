const { expect } = require("chai");
const { sleep } = require("@nomicfoundation/hardhat-verify/internal/utilities");
const { ethers } = require("hardhat");
const { MerkleTree } = require("merkletreejs");

describe("Rollup.sol", function () {
  let rollup;

  function calculateCommitmentHash(commitment) {
    return ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "bytes32", "bytes32", "bytes32"],
        [
          commitment.previousBlockHash,
          commitment.blockHash,
          commitment.withdrawalHash,
          commitment.depositHash,
        ]
      )
    );
  }

  function generateMerkleProof(commitmentBatch, indexInBatch) {
    const hashes = commitmentBatch.map(calculateCommitmentHash);
    const tree = new MerkleTree(hashes, ethers.keccak256, {
      sortPairs: false,
      duplicateOdd: true,
    });
    const proof = tree.getHexProof(hashes[indexInBatch]);
    // Return in MerkleTree.MerkleProof format
    return {
      proof: "0x" + proof.map(x => x.slice(2)).join(""),
      nonce: indexInBatch
    };
  }

  function generateRandomBlockHash() {
    return ethers.keccak256(ethers.randomBytes(32));
  }

  before(async function () {
    const Verifier = await ethers.getContractFactory("VerifierMock");
    let verifier = await Verifier.deploy();

    console.log("Verifier: ", verifier.target);

    const RollupContract = await ethers.getContractFactory("Rollup");
    const vkKey = "0x00612f9d5a388df116872ff70e36bcb86c7e73b1089f32f68fc8e0d0ba7861b7";
    const genesisHash = "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";
    const BridgeContract = await ethers.getContractFactory("Bridge");
    let bridge = await BridgeContract.deploy(
      "0x0000000000000000000000000000000000000000",
      "0x0000000000000000000000000000000000000000",
      0,
      "0x0000000000000000000000000000000000000001",
      "0x0000000000000000000000000000000000000002",
    );
    const accounts = await hre.ethers.getSigners();
    rollup = await RollupContract.deploy(
      accounts[0],
      10000,
      0,
      1,
      verifier.target,
      vkKey,
      genesisHash,
      bridge.target,
      2,
      10,
      1000,
    );

    await rollup.setDaCheck(false);
  });

  beforeEach(async function() {
    // Revert to batch 1 to ensure clean context
    const accounts = await hre.ethers.getSigners();
    const rollupContractWithSigner = rollup.connect(accounts[0]);
    const currentBatchIndex = await rollupContractWithSigner.nextBatchIndex();
    if (currentBatchIndex > 1) {
      await rollupContractWithSigner.forceRevertBatch(1, {value: 1000});
    }
  });

  it("Accept and prove block commitment", async function () {
    const accounts = await hre.ethers.getSigners();
    const rollupContractWithSigner = rollup.connect(accounts[0]);

    let batchIndex = await rollupContractWithSigner.nextBatchIndex();
    let prevBlockHash;
    if (batchIndex > 0n) {
      prevBlockHash = await rollupContractWithSigner.lastBlockHashInBatch(Number(batchIndex - 1n));
    } else {
      prevBlockHash = "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";
    }

    expect(await rollupContractWithSigner.acceptedBatch(batchIndex)).to.eq(false);
    expect(await rollupContractWithSigner.approvedBatch(batchIndex)).to.eq(false);

    // Generate random block hashes
    const blockHash1 = generateRandomBlockHash();
    const blockHash2 = generateRandomBlockHash();

    const commitmentBatch = [
      {
        previousBlockHash: prevBlockHash, // use correct previous block hash
        blockHash: blockHash1,
        withdrawalHash: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        depositHash: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
      },
      {
        previousBlockHash: blockHash1, // connected to first block's hash
        blockHash: blockHash2,
        withdrawalHash: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        depositHash: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
      },
    ];

    // Accept the batch
    await rollupContractWithSigner.acceptNextBatch(batchIndex, commitmentBatch, []);
    let newBatchIndex = await rollupContractWithSigner.nextBatchIndex();
    expect(newBatchIndex).to.eq(batchIndex + 1n);
    expect(await rollupContractWithSigner.acceptedBatch(batchIndex)).to.eq(true);
    expect(await rollupContractWithSigner.lastBlockHashInBatch(batchIndex)).to.eq(commitmentBatch[1].blockHash);

    // Generate proof for first block commitment
    const blockProof = generateMerkleProof(commitmentBatch, 0);
    const commitmentHash = calculateCommitmentHash(commitmentBatch[0]);

    // Challenge the block commitment
    await rollupContractWithSigner.challengeBlockCommitment(
      batchIndex,
      commitmentBatch[0],
      blockProof,
      { value: 10000 }
    );

    // Verify challenge was recorded
    let challengeQueue = await rollupContractWithSigner.getChallengeQueue();
    expect(challengeQueue.length).to.eq(1);
    expect(challengeQueue[0]).to.eq(commitmentHash);

    // Prove the block commitment
    const zkProof = "0x11b6a09d2c70b2e4fb214226fd0106a590dca00c2a0ec62e34e7ffdd11c788703fc26d61035980a75458baf4393fdf65478f94d960953de6fd03f31fc868c8c93087c8662e985b53c4ac8502c1f917bb20968844d0d55eda08ed5d6144b4e5feaa8e444d103a3f3230489985fa76eb73f89fef51d2f7c5e0c184be7ab74f1c9640e6651618f259ab8d0616b26ff75ccfea92f789502b89892a6fb67ec47932f8f575d2a912ea41c5f75e0440efce92e9dc9cc43647989cd570404e88f757318e2ae5696a24cf008895debedf7735532ecaae629ff1a636493476f0cdf8aa7e05f4b792a7180e9a7f185b545461e083e9997b0a8fe3e1fe85cda87da247a07edc043c4a6e";
    
    await rollupContractWithSigner.proofBlockCommitment(
      batchIndex,
      commitmentBatch[0],
      zkProof,
      blockProof
    );

    // Verify challenge was resolved
    challengeQueue = await rollupContractWithSigner.getChallengeQueue();
    expect(challengeQueue.length).to.eq(0);

    // Verify block commitment is proven
    expect(await rollupContractWithSigner.provenBlockCommitment(commitmentHash)).to.eq(true);
  });

  it("Revert check with block commitments", async function () {
    const accounts = await hre.ethers.getSigners();
    const rollupContractWithSigner = rollup.connect(accounts[0]);

    let nextBatchIndex = await rollupContractWithSigner.nextBatchIndex();
    let prevBlockHash;
    if (nextBatchIndex > 0n) {
      prevBlockHash = await rollupContractWithSigner.lastBlockHashInBatch(Number(nextBatchIndex - 1n));
    } else {
      prevBlockHash = "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";
    }

    // Generate random block hashes
    const blockHash1 = generateRandomBlockHash();
    const blockHash2 = generateRandomBlockHash();

    const commitmentBatch = [
      {
        previousBlockHash: prevBlockHash, // use correct previous block hash
        blockHash: blockHash1,
        withdrawalHash: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        depositHash: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
      },
      {
        previousBlockHash: blockHash1, // connected to first block's hash
        blockHash: blockHash2,
        withdrawalHash: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        depositHash: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
      },
    ];

    // Accept batch
    await rollupContractWithSigner.acceptNextBatch(nextBatchIndex, commitmentBatch, []);
    expect(await rollupContractWithSigner.lastBlockHashInBatch(nextBatchIndex)).to.eq(commitmentBatch[1].blockHash);

    // Generate proof and challenge first block commitment
    const blockProof = generateMerkleProof(commitmentBatch, 0);
    await rollupContractWithSigner.challengeBlockCommitment(
      nextBatchIndex,
      commitmentBatch[0],
      blockProof,
      { value: 10000 }
    );

    expect(await rollupContractWithSigner.rollupCorrupted()).to.eq(false);

    // Wait for challenge deadline
    await accounts[0].sendTransaction({
      to: accounts[1].address,
      value: 10,
    });

    expect(await rollupContractWithSigner.rollupCorrupted()).to.eq(true);

    // Force revert the batch
    await rollupContractWithSigner.forceRevertBatch(nextBatchIndex, {value: 1000});
    expect(await rollupContractWithSigner.rollupCorrupted()).to.eq(false);
  });

  it("Test not allow to accept batch when pause", async function () {
    const accounts = await hre.ethers.getSigners();
    const contractWithSigner = rollup.connect(accounts[0]);

    let paused = await rollup.paused();
    expect(paused).to.equal(false);

    const pauseTx = await contractWithSigner.pause();

    await pauseTx.wait();

    paused = await rollup.paused();
    expect(paused).to.equal(true);

    try {
      const commitmentBatch = [
        {
          previousBlockHash: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
          blockHash: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
          withdrawalHash: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
          depositHash: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        },
        {
          previousBlockHash: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
          blockHash: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
          withdrawalHash: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
          depositHash: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        },
      ];

      await contractWithSigner.acceptNextBatch(0, commitmentBatch, []);
    } catch (error) {
      expect(error.message).to.include("EnforcedPause");
    }

    const unpauseTx = await contractWithSigner.unpause();

    await unpauseTx.wait();

    paused = await rollup.paused();
    expect(paused).to.equal(false);
  });


});
