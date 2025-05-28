const { expect } = require("chai");
const { ethers } = require("hardhat");
const { TestingCtx, log } = require("./helpers");
const { sleep } = require("@nomicfoundation/hardhat-verify/internal/utilities");
const { AbiCoder } = require("ethers");
const { MerkleTree } = require("merkletreejs");

const TX_RECEIPT_STATUS_SUCCESS = 1;
const TX_RECEIPT_STATUS_REVERT = 0;

describe("Accept Batch Tests", () => {
  let ctxL1;
  let ctxL2;
  let l2TokenContract, l1TokenContract;
  let l2GatewayContract, l1GatewayContract;
  let l2BridgeContract, l1BridgeContract;
  let l2ImplementationAddress, l1ImplementationAddress;
  let l2FactoryAddress, l1FactoryAddress;
  let rollupContract;
  let batchSize = 100;

  async function deployMockToken(ctx, owner) {
    const mockErc20TokenFactory = await ethers.getContractFactory("MockERC20Token");
    const tokenContract = await mockErc20TokenFactory
      .connect(owner)
      .deploy("Mock Token", "TKN", ethers.parseEther("10"), owner.address, {
        gasLimit: 30_000_000,
      });
    await tokenContract.waitForDeployment();
    log("Mock Token contract deployed at:", tokenContract.target);
    return tokenContract;
  }

  async function setOtherSide(gateway, otherSideAddress, implementationAddress, factoryAddress) {
    log("Setting other side for gateway:", gateway.target);
    log("Other side address:", otherSideAddress);
    log("Implementation address:", implementationAddress);
    log("Factory address:", factoryAddress);
    
    const tx = await gateway.setOtherSide(otherSideAddress, implementationAddress, factoryAddress);
    const receipt = await tx.wait();
    expect(receipt.status).to.eq(TX_RECEIPT_STATUS_SUCCESS);
    log("Other side set successfully");
  }

  async function deployVerifierAndRollup(owner, batchSize, genesisHash) {
    const VerifierContract = await ethers.getContractFactory("VerifierMock");
    const verifier = await VerifierContract.deploy();
    await verifier.waitForDeployment();
    log("Verifier contract deployed at:", verifier.target);
    log("Using L1 genesis hash for rollup:", genesisHash);

    const rollupFactory = await ethers.getContractFactory("Rollup");
    const vkKey = "0x00612f9d5a388df116872ff70e36bcb86c7e73b1089f32f68fc8e0d0ba7861b7";

    const rollupContract = await rollupFactory
      .connect(owner)
      .deploy(owner.address, 0, 0, 0, verifier.target, vkKey, genesisHash,
        "0x0000000000000000000000000000000000000000", batchSize, 1000, 0);
    
    const receipt = await rollupContract.deploymentTransaction().wait();
    expect(receipt.status).to.eq(TX_RECEIPT_STATUS_SUCCESS);
    log("Rollup contract deployed at:", rollupContract.target);
    return rollupContract;
  }

  async function deployBridgeSystem(ctx, owner, rollupAddress, receiveDeadline = 0) {
    log(`Deploying bridge system for ${ctx.networkName} (rollupAddress=${rollupAddress})`);
    
    // Deploy pegged token
    const erc20PeggedTokenFactory = await ethers.getContractFactory("ERC20PeggedToken");
    const peggedTokenContract = await erc20PeggedTokenFactory.connect(owner).deploy({
      gasLimit: 30_000_000,
    });
    await peggedTokenContract.waitForDeployment();
    log("Pegged Token contract deployed at:", peggedTokenContract.target);

    // Deploy bridge
    const bridgeFactory = await ethers.getContractFactory("Bridge");
    const bridgeContract = await bridgeFactory
      .connect(owner)
      .deploy(owner.address, rollupAddress, receiveDeadline);
    await bridgeContract.waitForDeployment();
    log("Bridge contract deployed at:", bridgeContract.target);

    if (rollupAddress !== "0x0000000000000000000000000000000000000000") {
      log("Setting bridge in rollup contract");
      const setBridgeTx = await rollupContract.setBridge(bridgeContract.target);
      const receipt = await setBridgeTx.wait();
      expect(receipt.status).to.eq(TX_RECEIPT_STATUS_SUCCESS);
      log("Bridge set in rollup contract");
    }

    // Deploy token factory
    const erc20TokenFactory = await ethers.getContractFactory("ERC20TokenFactory");
    const tokenFactoryContract = await erc20TokenFactory
      .connect(owner)
      .deploy(peggedTokenContract.target);
    await tokenFactoryContract.waitForDeployment();
    log("Token Factory contract deployed at:", tokenFactoryContract.target);

    // Deploy gateway
    const erc20GatewayFactory = await ethers.getContractFactory("ERC20Gateway");
    const gatewayContract = await erc20GatewayFactory
      .connect(owner)
      .deploy(bridgeContract.target, tokenFactoryContract.target, {
        value: ethers.parseEther("1000"),
        gasLimit: 30_000_000,
      });
    await gatewayContract.waitForDeployment();
    log("Gateway contract deployed at:", gatewayContract.target);

    // Transfer ownership
    log("Transferring token factory ownership to gateway");
    const transferOwnershipTx = await tokenFactoryContract.transferOwnership(gatewayContract.target);
    const receipt = await transferOwnershipTx.wait();
    expect(receipt.status).to.eq(TX_RECEIPT_STATUS_SUCCESS);
    log("Token factory ownership transferred to:", gatewayContract.target);

    return [
      gatewayContract,
      bridgeContract,
      peggedTokenContract.target,
      tokenFactoryContract.target,
    ];
  }

  async function createBlockCommitment(block, withdrawalEvents, depositEvents) {
    const withdrawalRoot = withdrawalEvents.length > 0
      ? withdrawalEvents[0].args["messageHash"]
      : "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";

    const depositHash = depositEvents.length > 0
      ? ethers.keccak256(AbiCoder.defaultAbiCoder().encode(["bytes32"],[depositEvents[0].args["messageHash"]]))
      : "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";

    // Get genesis block hash for zero parent hash case
    let previousBlockHash = block.parentHash;
    if (previousBlockHash === "0x0000000000000000000000000000000000000000000000000000000000000000") {
      const genesisBlock = await block.provider.getBlock(0);
      previousBlockHash = genesisBlock.hash;
      log("Using genesis hash for block with zero parent hash:", previousBlockHash, block.parentHash, block.number);
    }

    return {
      previousBlockHash,
      blockHash: block.hash,
      withdrawalHash: withdrawalRoot,
      depositHash: depositHash
    };
  }

  async function generateMerkleProof(commitmentBatch, indexInBatch) {
    const hashes = commitmentBatch.map((item) => {
      return ethers.keccak256(
        AbiCoder.defaultAbiCoder().encode(
          ["bytes32", "bytes32", "bytes32", "bytes32"],
          [
            item.previousBlockHash,
            item.blockHash,
            item.withdrawalHash,
            item.depositHash,
          ],
        ),
      );
    });

    const tree = new MerkleTree(hashes, ethers.keccak256, {
      sortPairs: false,
      duplicateOdd: true,
    });

    const merkleProofs = getFullProofWithDuplicatesHex(tree, Number(indexInBatch));
    return "0x" + merkleProofs.map(x => x.slice(2)).join("");
  }

  function getFullProofWithDuplicatesHex(tree, leafIndex) {
    const layers = tree.getLayers();
    let index = leafIndex;
    let proof = [];

    for (let i = 0; i < layers.length - 1; i++) {
      const layer = layers[i];
      let pairIndex = index ^ 1;
      
      if (pairIndex >= layer.length) {
        proof.push('0x' + layer[index].toString('hex'));
      } else {
        proof.push('0x' + layer[pairIndex].toString('hex'));
      }

      index = Math.floor(index / 2);
    }

    return proof;
  }

  async function sendTokensInBatch(gateway, token, recipient, amount, batchSize, startNonce) {
    const sendPromises = Array(batchSize).fill().map(async (_, i) => {
      const tx = await gateway.sendTokens(token.target, recipient.address, amount, {
        gasLimit: 30_000_000,
        nonce: startNonce + i
      });
      const receipt = await tx.wait();
      expect(receipt.status).to.eq(TX_RECEIPT_STATUS_SUCCESS);
      return receipt;
    });
    return Promise.all(sendPromises);
  }

  async function processMessages(bridge, events, startNonce) {
    const receivePromises = events.map(async (event, i) => {
      const tx = await bridge.receiveMessage(
        event.args["sender"],
        event.args["to"],
        event.args["value"],
        event.args["chainId"].toString(),
        event.args["blockNumber"],
        event.args["nonce"],
        event.args["data"],
        {
          gasLimit: 30_000_000,
          nonce: startNonce + i
        }
      );
      const receipt = await tx.wait();
      expect(receipt.status).to.eq(TX_RECEIPT_STATUS_SUCCESS);
      return receipt;
    });
    return Promise.all(receivePromises);
  }

  before(async () => {
    ctxL1 = TestingCtx.new_L1();
    ctxL2 = TestingCtx.new_L2();

    await ctxL1.printDebugInfoAsync();
    await ctxL2.printDebugInfoAsync();

    const [ownerL1] = ctxL1.accounts;
    const [ownerL2] = ctxL2.accounts;

    // Get L1 genesis block hash
    const l1GenesisBlock = await ctxL1.provider.getBlock(0);
    const l1GenesisHash = l1GenesisBlock.hash;
    log("L1 genesis block hash:", l1GenesisHash);

    // Deploy L2 contracts using L1 genesis hash
    rollupContract = await deployVerifierAndRollup(ownerL2, batchSize, l1GenesisHash);
    [l2GatewayContract, l2BridgeContract, l2ImplementationAddress, l2FactoryAddress] = 
      await deployBridgeSystem(ctxL2, ownerL2, rollupContract.target);

    // Deploy L1 contracts
    [l1GatewayContract, l1BridgeContract, l1ImplementationAddress, l1FactoryAddress] = 
      await deployBridgeSystem(ctxL1, ownerL1, "0x0000000000000000000000000000000000000000", 10);

    // Deploy mock tokens
    l1TokenContract = await deployMockToken(ctxL1, ownerL1);
    l2TokenContract = await deployMockToken(ctxL2, ownerL2);

    // Link bridges
    await setOtherSide(l2GatewayContract, l1GatewayContract.target, l1ImplementationAddress, l1FactoryAddress);
    await setOtherSide(l1GatewayContract, l2GatewayContract.target, l2ImplementationAddress, l2FactoryAddress);
  });

  it("Compare pegged token addresses", async function () {
    const peggedTokenAddress = await l2GatewayContract.computePeggedTokenAddress(l2TokenContract.target);
    const otherSidePeggedTokenAddress = await l1GatewayContract.computeOtherSidePeggedTokenAddress(l2TokenContract.target);
    expect(peggedTokenAddress).to.equal(otherSidePeggedTokenAddress);
  });

  it("Should accept batch and process messages", async function () {
    // Step 1: L2 -> L1 Transfer
    const approveTx = await l2TokenContract.approve(l2GatewayContract.target, 10 * batchSize);
    const approveReceipt = await approveTx.wait();
    expect(approveReceipt.status).to.eq(TX_RECEIPT_STATUS_SUCCESS);

    const [ownerL1] = ctxL1.accounts;
    const [ownerL2] = ctxL2.accounts;
    
    let nonce = await ctxL2.provider.getTransactionCount(ctxL2.owner(), "pending");
    const l2SendReceipts = await sendTokensInBatch(l2GatewayContract, l2TokenContract, ownerL1, 10, batchSize, nonce);
    
    const l2SendEvents = await l2BridgeContract.queryFilter(
      "SentMessage",
      l2SendReceipts[0].blockNumber
    );
    expect(l2SendEvents.length).to.eq(batchSize);

    // Process L2->L1 messages
    nonce = await ctxL1.provider.getTransactionCount(ctxL1.owner(), "pending");
    await processMessages(l1BridgeContract, l2SendEvents, nonce);

    // Step 2: L1 -> L2 Transfer
    const l1ApproveTx = await l1TokenContract.approve(l1GatewayContract.target, 10 * batchSize);
    const l1ApproveReceipt = await l1ApproveTx.wait();
    expect(l1ApproveReceipt.status).to.eq(TX_RECEIPT_STATUS_SUCCESS);

    nonce = await ctxL1.provider.getTransactionCount(ctxL1.owner(), "pending");
    const l1SendReceipts = await sendTokensInBatch(l1GatewayContract, l1TokenContract, ownerL2, 10, batchSize, nonce);

    const l1SendEvents = await l1BridgeContract.queryFilter(
      "SentMessage",
      l1SendReceipts[0].blockNumber
    );
    expect(l1SendEvents.length).to.eq(batchSize);

    // Build and accept batches
    const latestBlock = await ctxL1.provider.getBlockNumber();
    let currentBatch = [];
    const allBatches = [];
    const depositsInBatches = [];
    let depositsInCurrentBatch = [];
    
    for (let blockNumber = 0; blockNumber <= latestBlock; blockNumber++) {
      const block = await ctxL1.provider.getBlock(blockNumber);
      const withdrawalEvents = await l1BridgeContract.queryFilter("SentMessage", blockNumber, blockNumber);
      const depositEvents = await l2BridgeContract.queryFilter("ReceivedMessage", blockNumber, blockNumber);
      
      const commitment = await createBlockCommitment(block, withdrawalEvents, depositEvents);
      currentBatch.push(commitment);

      depositsInCurrentBatch.push({
        blockHash: block.hash,
        depositCount: depositEvents.length
      });

      if (currentBatch.length === batchSize) {
        allBatches.push(currentBatch);
        depositsInBatches.push(depositsInCurrentBatch);
        currentBatch = [];
        depositsInCurrentBatch = [];
      }
    }

    // Accept batches with deposits
    for (let i = 0; i < allBatches.length; i++) {
      const batch = allBatches[i];
      const deposits = depositsInBatches[i];
      const nextBatchIndex = await rollupContract.nextBatchIndex();
      
      const acceptTx = await rollupContract.acceptNextBatch(nextBatchIndex, batch, deposits, {
        gasLimit: 30_000_000
      });
      const acceptReceipt = await acceptTx.wait();
      expect(acceptReceipt.status).to.eq(TX_RECEIPT_STATUS_SUCCESS);
      await sleep(1000);
    }

    // Process messages with proofs
    const nextBatchIndex = await rollupContract.nextBatchIndex();
    nonce = await ctxL2.provider.getTransactionCount(ctxL2.owner(), "pending");
    
    const processPromises = l1SendEvents.map(async (event, i) => {
      const batchIndex = event.args["blockNumber"] / 100n;
      if (batchIndex >= nextBatchIndex) return;

      const commitmentBatch = allBatches[Number(batchIndex)];
      const indexInBatch = event.args["blockNumber"] % 100n;

      if (await l2BridgeContract.receivedMessage(event.args["messageHash"])) {
        return;
      }

      const merkleProof = await generateMerkleProof(commitmentBatch, indexInBatch);

      const receiveTx = await l2BridgeContract.receiveMessageWithProof(
        batchIndex,
        commitmentBatch[indexInBatch],
        event.args["sender"],
        event.args["to"],
        event.args["value"].toString(),
        event.args["chainId"].toString(),
        event.args["blockNumber"].toString(),
        event.args["nonce"].toString(),
        event.args["data"],
        { nonce: 0, proof: "0x" },
        { nonce: indexInBatch, proof: merkleProof },
        { gasLimit: 30_000_000, nonce: nonce + i }
      );
      const receiveReceipt = await receiveTx.wait();
      expect(receiveReceipt.status).to.eq(TX_RECEIPT_STATUS_SUCCESS);
      return receiveReceipt;
    });

    const processReceipts = await Promise.all(processPromises.filter(p => p));
    log(`Successfully processed ${processReceipts.length} messages with proofs`);
  });
});
