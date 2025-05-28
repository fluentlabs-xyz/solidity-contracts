const { expect } = require("chai");
const { sleep } = require("@nomicfoundation/hardhat-verify/internal/utilities");
const { ethers } = require("hardhat");


describe("Verifier", function () {
  let rollup;
  const genesisHash = "0x9d06b07ccbd86a2fc8ab4145d909873c09d92bbce87f98f33699ff3733e91a2c";
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

  before(async function () {
    const Verifier = await ethers.getContractFactory("SP1Verifier");
    let verifier = await Verifier.deploy();



    console.log("Verifier: ", verifier.target);

    const RollupContract = await ethers.getContractFactory("Rollup");
    const vkKey = "0x00440704be87894021b2b5673900bf717ec670dcfde36f7bf371f9ae1a02f46e";

    const BridgeContract = await ethers.getContractFactory("Bridge");
    let bridge = await BridgeContract.deploy(
      "0x0000000000000000000000000000000000000000",
      "0x0000000000000000000000000000000000000000",
      0,
    );

    rollup = await RollupContract.deploy(
      10000,
      0,
      1,
      verifier.target,
      vkKey,
      genesisHash,
      bridge.target,
      1,
      10,
      1000,
    );
    await rollup.setDaCheck(false);
  });

  it("Accept and prove block commitment", async function () {
    const accounts = await hre.ethers.getSigners();
    const rollupContractWithSigner = rollup.connect(accounts[0]);

    let batchIndex = await rollupContractWithSigner.nextBatchIndex();

    expect(await rollupContractWithSigner.acceptedBatch(batchIndex)).to.eq(false);
    expect(await rollupContractWithSigner.approvedBatch(batchIndex)).to.eq(false);

    let blockHash = "0x931c2be30add0b25a64c8b07103fe5ffdab5b58d0ca095c9e6259bfe740fff13";

    const commitmentBatch = [
      {
        previousBlockHash: genesisHash, // use correct previous block hash
        blockHash: blockHash,
        withdrawalHash: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        depositHash: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
      },
    ];

    // Accept the batch
    await rollupContractWithSigner.acceptNextBatch(batchIndex, commitmentBatch, []);
    let newBatchIndex = await rollupContractWithSigner.nextBatchIndex();
    expect(newBatchIndex).to.eq(batchIndex + 1n);
    expect(await rollupContractWithSigner.acceptedBatch(batchIndex)).to.eq(true);
    expect(await rollupContractWithSigner.lastBlockHashInBatch(batchIndex)).to.eq(commitmentBatch[0].blockHash);

    const commitmentHash = calculateCommitmentHash(commitmentBatch[0]);

    // Challenge the block commitment
    await rollupContractWithSigner.challengeBlockCommitment(
      batchIndex,
      commitmentBatch[0],
      {
        nonce: 0,
        proof: "0x"
      },
      { value: 10000 }
    );


    // Prove the block commitment
    const zkProof = "0x11b6a09d04e5edb1f55a53f6739a6934d3afb512e89bc5074501f23bfe46114230aa869a2887f02ef2817aff64d87d334c62a0e06a2dba798d8aaecde83e8c5ad0ddd9780433b562d8fb68f3fc43c0fa330f7400d07a87a06b62a487eb04ace591d616342d713a0a1cb4f856d2ed16dd14181adcc1516fb1f817676f3a58fd249e46bb78076291c99809d829eb9f9a34cd35eb5410eb49e45e1fa5839ecb574c4a758d8b122afd35de775bf41a3daa732a095b09beaa9648da9340a81b55574395f8829918327d8ff67bdd5ea02a778c4f252ee8a87b1b99fba0365843d581823e41a1d52dc64f4a5b2bba4190a6074a89d52e51b4f06c661963a9aae976c1550a5821fa";
    
    await rollupContractWithSigner.proofBlockCommitment(
      batchIndex,
      commitmentBatch[0],
      zkProof,
      {
        nonce: 0,
        proof: "0x"
      },
    );

    // Verify challenge was resolved
    challengeQueue = await rollupContractWithSigner.getChallengeQueue();
    expect(challengeQueue.length).to.eq(0);

    // Verify block commitment is proven
    expect(await rollupContractWithSigner.proofedBlockCommitment(commitmentHash)).to.eq(true);
  });
});
