const { expect } = require("chai");
const { ethers } = require("hardhat");
const { TestingCtx, log } = require("./helpers");
const { sleep } = require("@nomicfoundation/hardhat-verify/internal/utilities");

const TX_RECEIPT_STATUS = {
  SUCCESS: 1,
  REVERT: 0
};

const MOCK_ROLLUP_CONFIG = {
  vkKey: "0x00612f9d5a388df116872ff70e36bcb86c7e73b1089f32f68fc8e0d0ba7861b7",
  genesisHash: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
  zeroAddress: "0x0000000000000000000000000000000000000000"
};

class BridgeTestContext {
  constructor() {
    this.ctxL1 = TestingCtx.new_L1();
    this.ctxL2 = TestingCtx.new_L2();
  }

  async initialize() {
    await this.ctxL1.printDebugInfoAsync();
    await this.ctxL2.printDebugInfoAsync();

    const [ownerL2] = this.ctxL2.accounts;
    
    // Setup L2 chain with rollup
    [
      this.l2GatewayContract,
      this.l2BridgeContract,
      this.l2ImplementationAddress,
      this.l2FactoryAddress,
      this.rollupContract,
    ] = await this.setupChain(this.ctxL2, true);

    // Setup L1 chain without rollup
    [
      this.l1GatewayContract,
      this.l1BridgeContract,
      this.l1ImplementationAddress,
      this.l1FactoryAddress,
    ] = await this.setupChain(this.ctxL1, false, 10);

    // Deploy mock token on L2
    this.l2TokenContract = await this.deployMockToken(ownerL2);

    // Link the bridges
    await this.linkBridges();
  }

  async deployMockToken(owner) {
    log("Deploying mock token contract");
    const mockErc20TokenFactory = await ethers.getContractFactory("MockERC20Token");
    const tokenContract = await mockErc20TokenFactory
      .connect(owner)
      .deploy("Mock Token", "TKN", ethers.parseEther("10"), owner.address, {
        gasLimit: 30_000_000,
      });
    await tokenContract.waitForDeployment();
    log(`Mock token deployed at: ${tokenContract.target}`);
    return tokenContract;
  }

  async linkBridges() {
    log("Linking L1 and L2 bridges");
    
    // Set L1 gateway as other side for L2
    let tx = await this.l2GatewayContract.setOtherSide(
      this.l1GatewayContract.target,
      this.l1ImplementationAddress,
      this.l1FactoryAddress
    );
    let receipt = await tx.wait();
    expect(receipt.status).to.eq(TX_RECEIPT_STATUS.SUCCESS);

    // Set L2 gateway as other side for L1
    tx = await this.l1GatewayContract.setOtherSide(
      this.l2GatewayContract.target,
      this.l2ImplementationAddress,
      this.l2FactoryAddress
    );
    receipt = await tx.wait();
    expect(receipt.status).to.eq(TX_RECEIPT_STATUS.SUCCESS);
  }

  async setupChain(ctx, withRollup = false, receiveDeadLine = 0) {
    log(`Setting up chain for ${ctx.networkName} (withRollup=${withRollup})`);
    const owner = ctx.owner();

    // Deploy pegged token contract
    const peggedToken = await this.deployPeggedToken(owner);

    // Deploy rollup if needed
    const rollup = withRollup ?
      await this.deployRollup(owner) : 
      null;

    // Deploy and setup bridge
    const bridge = await this.deployBridge(owner, withRollup? rollup.target: MOCK_ROLLUP_CONFIG.zeroAddress, receiveDeadLine);
    
    if (withRollup) {
      await this.linkRollupToBridge(rollup, bridge.target);
    }

    // Deploy and setup token factory and gateway
    const [gateway, factory] = await this.deployTokenFactoryAndGateway(owner, bridge, peggedToken);

    return [gateway, bridge, peggedToken.target, factory.target, rollup];
  }

  async deployPeggedToken(owner) {
    const factory = await ethers.getContractFactory("ERC20PeggedToken");
    const contract = await factory.connect(owner).deploy({ gasLimit: 30_000_000 });
    await contract.waitForDeployment();
    log("Pegged token deployed at:", contract.target);
    return contract;
  }

  async deployRollup(owner) {
    const verifierFactory = await ethers.getContractFactory("VerifierMock");
    const verifier = await verifierFactory.connect(owner).deploy();
    await verifier.waitForDeployment();
    
    const rollupFactory = await ethers.getContractFactory("Rollup");
    const rollup = await rollupFactory
      .connect(owner)
      .deploy(
        owner.address,
        0, 0, 0,
        verifier.target,
        MOCK_ROLLUP_CONFIG.vkKey,
        MOCK_ROLLUP_CONFIG.genesisHash,
        MOCK_ROLLUP_CONFIG.zeroAddress,
        1,
        100,
        0
      );
    await rollup.waitForDeployment();
    log("Rollup contract deployed at:", rollup.target);
    return rollup;
  }

  async deployBridge(owner, rollupAddress, receiveDeadLine) {
    const factory = await ethers.getContractFactory("Bridge");
    const bridge = await factory
      .connect(owner)
      .deploy(owner.address, rollupAddress, receiveDeadLine);
    await bridge.waitForDeployment();
    log("Bridge deployed at:", bridge.target);
    return bridge;
  }

  async linkRollupToBridge(rollup, bridgeAddress) {
    const tx = await rollup.setBridge(bridgeAddress);
    await tx.wait();
    log("Rollup linked to bridge");
  }

  async deployTokenFactoryAndGateway(owner, bridge, peggedToken) {
    // Deploy token factory
    const factoryContract = await ethers.getContractFactory("ERC20TokenFactory");
    const factory = await factoryContract
      .connect(owner)
      .deploy(peggedToken.target);
    await factory.waitForDeployment();
    log("Token factory deployed at:", factory.target);

    // Deploy gateway
    const gatewayFactory = await ethers.getContractFactory("ERC20Gateway");
    const gateway = await gatewayFactory
      .connect(owner)
      .deploy(bridge.target, factory.target, {
        value: ethers.parseEther("1000"),
        gasLimit: 30_000_000,
      });
    await gateway.waitForDeployment();
    log("Gateway deployed at:", gateway.target);

    // Transfer factory ownership to gateway
    await factory.transferOwnership(gateway.target);
    log("Factory ownership transferred to gateway");

    return [gateway, factory];
  }

  async approveTokensForBridge() {
    log("Approving tokens for bridging");
    const tx = await this.l2TokenContract.approve(
      this.l2GatewayContract.target,
      10,
      {
        gasLimit: 30_000_000,
      }
    );
    const receipt = await tx.wait();
    expect(receipt.status).to.eq(TX_RECEIPT_STATUS.SUCCESS);
  }

  async bridgeTokensL2ToL1() {
    log("Bridging tokens from L2 to L1");
    const [ownerL1] = this.ctxL1.accounts;

    // Send tokens from L2 to L1
    const sendTx = await this.l2GatewayContract.sendTokens(
      this.l2TokenContract.target,
      ownerL1.address,
      10,
      {
        gasLimit: 30_000_000,
      }
    );
    const sendReceipt = await sendTx.wait();
    expect(sendReceipt.status).to.eq(TX_RECEIPT_STATUS.SUCCESS);

    // Get sent message events
    const sentEvents = await this.l2BridgeContract.queryFilter(
      "SentMessage",
      sendReceipt.blockNumber
    );
    expect(sentEvents.length).to.equal(1);
    console.log("Send from L2 to L1 events: ", sentEvents);

    // Process message on L1
    await this.processMessageOnL1(sentEvents[0]);

    return sentEvents;
  }

  async processMessageOnL1(sentEvent) {
    log("Processing message on L1");
    const tx = await this.l1BridgeContract.receiveMessage(
      sentEvent.args.sender,
      sentEvent.args.to,
      sentEvent.args.value,
      sentEvent.args.chainId.toString(),
      sentEvent.args.blockNumber,
      sentEvent.args.nonce,
      sentEvent.args.data
    );
    const receipt = await tx.wait();
    expect(receipt.status).to.eq(TX_RECEIPT_STATUS.SUCCESS);

    // Verify events
    const receivedEvents = await this.l1BridgeContract.queryFilter(
      "ReceivedMessage",
      receipt.blockNumber
    );
    const tokenEvents = await this.l1GatewayContract.queryFilter(
      "ReceivedTokens",
      receipt.blockNumber
    );
    expect(receivedEvents.length).to.equal(1);
    expect(tokenEvents.length).to.equal(1);
  }

  async bridgeTokensL1ToL2(l2ToL1Events) {
    log("Bridging tokens back from L1 to L2");
    
    // Get pegged token address and send tokens back
    const peggedTokenAddress = await this.l1GatewayContract.computePeggedTokenAddress(
      this.l2TokenContract.target
    );
    const l1Addresses = await this.ctxL2.listAddresses();
    
    const sendTx = await this.l1GatewayContract.sendTokens(
      peggedTokenAddress,
      l1Addresses[3],
      10
    );
    const sendReceipt = await sendTx.wait();
    expect(sendReceipt.status).to.eq(TX_RECEIPT_STATUS.SUCCESS);

    // Get sent message events
    const sentEvents = await this.l1BridgeContract.queryFilter(
      "SentMessage",
      l2ToL1Events[0].blockNumber
    );
    expect(sentEvents.length).to.equal(1);
    console.log("Send from L1 to L2 enents: ", sentEvents);

    // Process message on L2 with proof
    await this.processMessageOnL2WithProof(sentEvents[0], l2ToL1Events[0], sendReceipt);
  }

  async processMessageOnL2WithProof(sentEvent, originalL2Event, sendReceipt) {
    log("Processing message on L2 with proof");
    
    const messageHash = originalL2Event.args.messageHash;
    const depositHash = ethers.keccak256(messageHash);

    const commitmentBatch = [{
      previousBlockHash: MOCK_ROLLUP_CONFIG.genesisHash,
      blockHash: sendReceipt.blockHash,
      withdrawalHash: sentEvent.args.messageHash,
      depositHash: depositHash
    }];

    const depositsInBlock = [{
      blockHash: sendReceipt.blockHash,
      depositCount: 1
    }];

    // Accept batch on rollup
    const nextBatchIndex = await this.rollupContract.nextBatchIndex();
    console.log("Next batch index", nextBatchIndex);
    const acceptTx = await this.rollupContract.acceptNextBatch(
      nextBatchIndex,
      commitmentBatch,
      depositsInBlock,
      {
        gasLimit: 30_000_000
      }
    );
    const acceptReceipt = await acceptTx.wait();
    expect(acceptReceipt.status).to.eq(TX_RECEIPT_STATUS.SUCCESS);

    // Receive message with proof on L2
    const receiveTx = await this.l2BridgeContract.receiveMessageWithProof(
      nextBatchIndex,
      commitmentBatch[0],
      sentEvent.args.sender,
      sentEvent.args.to,
      sentEvent.args.value.toString(),
      sentEvent.args.chainId.toString(),
      sentEvent.args.blockNumber.toString(),
      sentEvent.args.nonce.toString(),
      sentEvent.args.data,
      {
        nonce: 0,
        proof: "0x"
      },
      {
        nonce: 0,
        proof: "0x"
      },
      {
        gasLimit: 30_000_000
      }
    );
    const receiveReceipt = await receiveTx.wait();
    expect(receiveReceipt.status).to.eq(TX_RECEIPT_STATUS.SUCCESS);

    // Verify events
    const receivedEvents = await this.l2BridgeContract.queryFilter(
      "ReceivedMessage",
      receiveReceipt.blockNumber
    );
    const tokenEvents = await this.l2GatewayContract.queryFilter(
      "ReceivedTokens",
      receiveReceipt.blockNumber
    );
    expect(receivedEvents.length).to.equal(1);
    expect(tokenEvents.length).to.equal(1);
  }
}

describe("Token Bridge Integration Tests", () => {
  let testContext;

  before(async () => {
    testContext = new BridgeTestContext();
    await testContext.initialize();
  });

  describe("Token Address Verification", () => {
    it("should compute matching pegged token addresses on L1 and L2", async () => {
      const l2PeggedAddress = await testContext.l2GatewayContract.computePeggedTokenAddress(
        testContext.l2TokenContract.target
      );
      const l1PeggedAddress = await testContext.l1GatewayContract.computeOtherSidePeggedTokenAddress(
        testContext.l2TokenContract.target
      );
      expect(l2PeggedAddress).to.equal(l1PeggedAddress);
    });
  });

  describe("Token Bridge Operations", () => {
    it("should successfully bridge tokens from L2 to L1 and back", async () => {
      // First approve tokens for bridging
      await testContext.approveTokensForBridge();

      // Bridge tokens from L2 to L1
      const l2ToL1Events = await testContext.bridgeTokensL2ToL1();
      
      // Bridge tokens back from L1 to L2
      await testContext.bridgeTokensL1ToL2(l2ToL1Events);
    });
  });
});
