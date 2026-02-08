const { expect } = require("chai");
const { ethers } = require("hardhat");

/**
 * Hardhat-only end-to-end test for the ERC20 bridge using pegged tokens.
 * This exercises the full L2 -> L1 -> L2 flow without depending on
 * external RPC endpoints or the Fluent UST precompile.
 */
describe("Bridge Integration (pegged tokens) on hardhat network", () => {
  let deployer;
  let userL1;
  let userL2;

  let bridgeL1;
  let bridgeL2;
  let gatewayL1;
  let gatewayL2;
  let legacyFactoryL1;
  let legacyFactoryL2;

  let originTokenL2;

  before(async () => {
    [deployer, userL1, userL2] = await ethers.getSigners();

    // Deploy Bridges (simulate L1 and L2 on same hardhat network)
    const Bridge = await ethers.getContractFactory("Bridge");

    bridgeL1 = await Bridge.connect(deployer).deploy(
      deployer.address,
      ethers.ZeroAddress,
      0,
      ethers.ZeroAddress,
      ethers.ZeroAddress
    );
    await bridgeL1.waitForDeployment();

    bridgeL2 = await Bridge.connect(deployer).deploy(
      deployer.address,
      ethers.ZeroAddress,
      10,
      ethers.ZeroAddress,
      ethers.ZeroAddress
    );
    await bridgeL2.waitForDeployment();

    // Deploy legacy pegged token impl for factory ctor (one per side)
    const PeggedToken = await ethers.getContractFactory("ERC20PeggedToken");
    const peggedImplL1 = await PeggedToken.connect(deployer).deploy();
    await peggedImplL1.waitForDeployment();
    const peggedImplL2 = await PeggedToken.connect(deployer).deploy();
    await peggedImplL2.waitForDeployment();

    // Deploy legacy factories (still required by constructor)
    const LegacyFactory = await ethers.getContractFactory("ERC20TokenFactory");
    legacyFactoryL1 = await LegacyFactory.connect(deployer).deploy(
      peggedImplL1.target
    );
    await legacyFactoryL1.waitForDeployment();
    legacyFactoryL2 = await LegacyFactory.connect(deployer).deploy(
      peggedImplL2.target
    );
    await legacyFactoryL2.waitForDeployment();

    // Deploy gateways
    const Gateway = await ethers.getContractFactory("ERC20Gateway");

    gatewayL1 = await Gateway.connect(deployer).deploy(
      bridgeL1.target,
      legacyFactoryL1.target,
      {
        value: ethers.parseEther("1000"),
      }
    );
    await gatewayL1.waitForDeployment();

    gatewayL2 = await Gateway.connect(deployer).deploy(
      bridgeL2.target,
      legacyFactoryL2.target,
      {
        value: ethers.parseEther("1000"),
      }
    );
    await gatewayL2.waitForDeployment();

    await legacyFactoryL1.transferOwnership(gatewayL1.target);
    await legacyFactoryL2.transferOwnership(gatewayL2.target);

    // Link gateways as each other's otherSide using legacy factories
    await (
      await gatewayL2.setOtherSide(
        gatewayL1.target,
        peggedImplL1.target,
        legacyFactoryL1.target
      )
    ).wait();

    await (
      await gatewayL1.setOtherSide(
        gatewayL2.target,
        peggedImplL2.target,
        legacyFactoryL2.target
      )
    ).wait();

    // Deploy origin token on "L2"
    const MockToken = await ethers.getContractFactory("MockERC20Token");
    originTokenL2 = await MockToken.connect(deployer).deploy(
      "Mock Token",
      "TKN",
      ethers.parseEther("1000"),
      userL2.address
    );
    await originTokenL2.waitForDeployment();

    // User L2 approves gatewayL2
    await (
      await originTokenL2
        .connect(userL2)
        .approve(gatewayL2.target, ethers.parseEther("100"))
    ).wait();

    // No UniversalTokenFactory configuration in this hardhat-only test
  });

  it("bridges origin tokens L2 -> L1 and back on hardhat", async () => {
    // -------- L2 -> L1 --------
    const amount = ethers.parseEther("10");

    const sendTxL2 = await gatewayL2
      .connect(userL2)
      .sendTokens(originTokenL2.target, userL1.address, amount);
    const sendRcptL2 = await sendTxL2.wait();

    const sentEventsL2 = await bridgeL2.queryFilter(
      "SentMessage",
      sendRcptL2.blockNumber
    );
    expect(sentEventsL2.length).to.equal(1);

    const evL2 = sentEventsL2[0];

    const recvTxL1 = await bridgeL1
      .connect(deployer)
      .receiveMessage(
        evL2.args.sender,
        evL2.args.to,
        evL2.args.value,
        evL2.args.chainId,
        evL2.args.blockNumber,
        evL2.args.nonce,
        evL2.args.data
      );
    const recvRcptL1 = await recvTxL1.wait();

    // We rely on balance checks below to validate successful receipt on L1.

    // Check that a pegged token was deployed and minted.
    // We get the actual address from the TokenDeployed event.
    const factoryEvents = await legacyFactoryL1.queryFilter(
      "TokenDeployed",
      recvRcptL1.blockNumber
    );
    expect(factoryEvents.length).to.be.greaterThan(0);
    const peggedAddress = factoryEvents[0].args._peggedToken;
    const PeggedInterface = await ethers.getContractFactory("ERC20PeggedToken");
    const peggedL1 = PeggedInterface.attach(peggedAddress);
    const balanceL1 = await peggedL1.balanceOf(userL1.address);
    expect(balanceL1).to.equal(amount);

    // -------- L1 -> L2 --------
    // Approve gatewayL1 to move pegged tokens
    await (
      await peggedL1.connect(userL1).approve(gatewayL1.target, amount)
    ).wait();

    const sendTxL1 = await gatewayL1
      .connect(userL1)
      .sendTokens(peggedAddress, userL2.address, amount);
    const sendRcptL1 = await sendTxL1.wait();

    const sentEventsL1 = await bridgeL1.queryFilter(
      "SentMessage",
      sendRcptL1.blockNumber
    );
    expect(sentEventsL1.length).to.equal(1);

    const evL1 = sentEventsL1[0];

    const recvTxL2 = await bridgeL2
      .connect(deployer)
      .receiveMessage(
        evL1.args.sender,
        evL1.args.to,
        evL1.args.value,
        evL1.args.chainId,
        evL1.args.blockNumber,
        evL1.args.nonce,
        evL1.args.data
      );
    const recvRcptL2 = await recvTxL2.wait();

    // We rely on final L2 balance check below to validate receipt on L2.

    const finalBalanceL2 = await originTokenL2.balanceOf(userL2.address);
    // User started with 1000, sent 10 to gateway, then got 10 back
    expect(finalBalanceL2).to.equal(ethers.parseEther("1000"));
  });
});
