const { expect } = require("chai");
const { ethers, artifacts } = require("hardhat");
const { TestingCtx, log } = require("./helpers");
const { sleep } = require("@nomicfoundation/hardhat-verify/internal/utilities");

describe("Contract deployment and interaction", function () {
  let ctxL1;
  let ctxL2;

  let l2FactoryAddress, l1FactoryAddress;
  let l2GatewayContract, l1GatewayContract;
  let l2BridgeContract, l1BridgeContract;
  let l2ImplementationAddress, l1ImplementationAddress;
  let l1TokenContract;
  let rollupContract;
  let l2RestakerGatewayContract, l1RestakerGatewayContract;
  let l2RestakerFactoryContract, l1RestakerFactoryContract;
  let l2RestakerImplementationContract, l1RestakerImplementationContract;
  let restakingPoolContract;
  let liquidityTokenContract;
  const RESTAKER_PROVIDER = "RESTAKER_PROVIDER";

  let l2GasLimit = 100_000_000;
  let l1GasLimit = 30000000;
  before(async () => {
    ctxL1 = TestingCtx.new_L1();
    ctxL2 = TestingCtx.new_L2();
    for (let v of [ctxL1, ctxL2]) {
      await v.printDebugInfoAsync();
    }

    // erc20GatewayContract, bridgeContract, erc20PeggedTokenContract.address, erc20TokenFactoryContract.address
    [
      l2GatewayContract,
      l2BridgeContract,
      l2ImplementationAddress,
      l2FactoryAddress,
    ] = await SetUpChain(ctxL2, true);
    [
      l1GatewayContract,
      l1BridgeContract,
      l1ImplementationAddress,
      l1FactoryAddress,
    ] = await SetUpChain(ctxL1);

    const mockERC20TokenFactory =
      await ethers.getContractFactory("MockERC20Token");
    l1TokenContract = await mockERC20TokenFactory
      .connect(ctxL2.owner())
      .deploy(
        "Mock Token",
        "TKN",
        ethers.parseEther("1000000"),
        ctxL1.owner().address,
      ); // Adjust initial supply as needed
    l1TokenContract = await l1TokenContract.waitForDeployment();
    log("l1TokenContract.address:", l1TokenContract.target);

    log("L1 gw:", l1GatewayContract.target, "L2 gw:", l2GatewayContract.target);

    [
      l2RestakerGatewayContract,
      restakingPoolContract,
      liquidityTokenContract,
      l2RestakerFactoryContract,
      l2RestakerImplementationContract,
    ] = await SetUpL2Restaker(l2BridgeContract.target);
    log("l2RestakerGatewayContract.address:", l2RestakerGatewayContract.target);

    [
      l1RestakerGatewayContract,
      l1RestakerFactoryContract,
      l1RestakerImplementationContract,
    ] = await SetUpL1Restaker(l1BridgeContract.target);

    l1RestakerGatewayContract.setLiquidityToken(liquidityTokenContract.target);
    log("L2 Restaker gateway: ", l1RestakerGatewayContract.target);
    let tx = await l2RestakerGatewayContract.setOtherSide(
      l1RestakerGatewayContract.target,
      l1RestakerImplementationContract.target,
      l1RestakerFactoryContract.target,
    );
    await tx.wait();
    tx = await l1RestakerGatewayContract.setOtherSide(
      l2RestakerGatewayContract.target,
      l2RestakerImplementationContract.target,
      l2RestakerFactoryContract.target,
    );
    await tx.wait();

    tx = await l2GatewayContract.setOtherSide(
      l1GatewayContract.target,
      l1ImplementationAddress,
      l1FactoryAddress,
    );
    await tx.wait();
    tx = await l1GatewayContract.setOtherSide(
      l2GatewayContract.target,
      l2ImplementationAddress,
      l2FactoryAddress,
    );
    await tx.wait();
  });

  async function SetUpL2Restaker(bridgeAddress) {
    let l2owner = ctxL2.owner();

    log(`protocolConfigContract started`);
    const protocolConfigFactory =
      await ethers.getContractFactory("ProtocolConfig");
    let protocolConfigContract = await protocolConfigFactory
      .connect(l2owner)
      .deploy(l2owner.address, l2owner.address, l2owner.address, {
        gasLimit: l2GasLimit,
      });
    protocolConfigContract = await protocolConfigContract.waitForDeployment();

    log(`ratioFeedFactory started`);
    await sleep(1000);
    const ratioFeedFactory = await ethers.getContractFactory("RatioFeed");
    let ratioFeedContract = await ratioFeedFactory
      .connect(l2owner)
      .deploy(protocolConfigContract.target, "40000", {
        gasLimit: l2GasLimit,
      });
    ratioFeedContract = await ratioFeedContract.waitForDeployment();

    log(`setRatioFeed started`);
    let setRatioFeedTx = await protocolConfigContract.setRatioFeed(
      ratioFeedContract.target,
    );
    await setRatioFeedTx.wait();

    log(`liquidityTokenContract started`);
    await sleep(1000);
    const LiquidityTokenFactory =
      await ethers.getContractFactory("LiquidityToken");
    let liquidityTokenContract = await LiquidityTokenFactory.connect(
      l2owner,
    ).deploy(protocolConfigContract.target, "Liquidity Token", "lETH", {
      gasLimit: l2GasLimit,
    });
    liquidityTokenContract = await liquidityTokenContract.waitForDeployment();

    log(`updateRatioTx started`);
    await sleep(1000);
    let updateRatioTx = await ratioFeedContract.updateRatio(
      liquidityTokenContract.target,
      1000,
      {
        gasLimit: l2GasLimit,
      },
    );
    await updateRatioTx.wait();

    log("liquidityTokenContract.address:", liquidityTokenContract.target);
    let setLiquidityTokenTx = await protocolConfigContract.setLiquidityToken(
      liquidityTokenContract.target,
    );
    await setLiquidityTokenTx.wait();

    log(`restakingPoolContract started`);
    await sleep(1000);
    const restakingPoolFactory =
      await ethers.getContractFactory("RestakingPool");
    let restakingPoolContract = await restakingPoolFactory
      .connect(l2owner)
      .deploy(
        protocolConfigContract.target,
        "200000",
        "200000000000000000000",
        {
          gasLimit: l2GasLimit,
        },
      );
    restakingPoolContract = await restakingPoolContract.waitForDeployment();
    log("restakingPoolContract.address:", restakingPoolContract.target);

    let setRestakingPoolTx = await protocolConfigContract.setRestakingPool(
      restakingPoolContract.target,
    );
    await setRestakingPoolTx.wait();

    log(`feeCollectorContract started`);
    await sleep(1000);
    const feeCollectorFactory = await ethers.getContractFactory("FeeCollector");
    let feeCollectorContract = await feeCollectorFactory
      .connect(l2owner)
      .deploy(protocolConfigContract.target, "1500", {
        gasLimit: l2GasLimit,
      });
    feeCollectorContract = await feeCollectorContract.waitForDeployment();

    log(`erc20PeggedTokenContract started`);
    const erc20PeggedTokenFactory =
      await ethers.getContractFactory("ERC20PeggedToken");
    let erc20PeggedTokenContract = await erc20PeggedTokenFactory
      .connect(l2owner)
      .deploy({
        gasLimit: l2GasLimit,
      });
    erc20PeggedTokenContract =
      await erc20PeggedTokenContract.waitForDeployment();

    log(`erc20TokenFactoryContract started`);
    await sleep(1000);
    const erc20TokenFactoryFactory =
      await ethers.getContractFactory("ERC20TokenFactory");
    let erc20TokenFactoryContract = await erc20TokenFactoryFactory
      .connect(l2owner)
      .deploy(erc20PeggedTokenContract.target, {
        gasLimit: l2GasLimit,
      });
    erc20TokenFactoryContract =
      await erc20TokenFactoryContract.waitForDeployment();

    log(`restakerGatewayContract started`);
    await sleep(1000);
    const restakerGatewayFactory =
      await ethers.getContractFactory("RestakerGateway");
    let restakerGatewayContract = await restakerGatewayFactory
      .connect(l2owner)
      .deploy(
        bridgeAddress,
        restakingPoolContract.target,
        erc20TokenFactoryContract.target,
        {
          // value: ethers.parseEther("50"),
          gasLimit: l2GasLimit,
        },
      );
    restakerGatewayContract = await restakerGatewayContract.waitForDeployment();
    log("restakerGatewayContract.address:", restakerGatewayContract.target);

    const eigenPodMockFactory = await ethers.getContractFactory("EigenPodMock");
    let eigenPodMockContract = await eigenPodMockFactory
      .connect(l2owner)
      .deploy(
        "0x0000000000000000000000000000000000000000",
        "0x0000000000000000000000000000000000000000",
        "0x0000000000000000000000000000000000000000",
        0,
        {
          gasLimit: l2GasLimit,
        },
      );
    eigenPodMockContract = await eigenPodMockContract.waitForDeployment();

    log(`restakerGatewayContract started`);
    const upgradeableBeaconFactory =
      await ethers.getContractFactory("UpgradeableBeacon");
    let upgradeableBeaconContract = await upgradeableBeaconFactory
      .connect(l2owner)
      .deploy(eigenPodMockContract.target, await l2owner.getAddress(), {
        gasLimit: l2GasLimit,
      });
    upgradeableBeaconContract =
      await upgradeableBeaconContract.waitForDeployment();

    log(`eigenPodManagerMockContract started`);
    const eigenPodManagerMockFactory = await ethers.getContractFactory(
      "EigenPodManagerMock",
    );
    let eigenPodManagerMockContract = await eigenPodManagerMockFactory
      .connect(l2owner)
      .deploy(
        "0x0000000000000000000000000000000000000000",
        upgradeableBeaconContract.target,
        "0x0000000000000000000000000000000000000000",
        "0x0000000000000000000000000000000000000000",
        {
          gasLimit: l2GasLimit,
        },
      );
    eigenPodManagerMockContract =
      await eigenPodManagerMockContract.waitForDeployment();

    log(`delegationManagerMockContract started`);
    const delegationManagerMockFactory = await ethers.getContractFactory(
      "DelegationManagerMock",
    );
    let delegationManagerMockContract = await delegationManagerMockFactory
      .connect(l2owner)
      .deploy({
        gasLimit: l2GasLimit,
      });
    delegationManagerMockContract =
      await delegationManagerMockContract.waitForDeployment();

    log(`restakerFacetsFactory started`);
    const restakerFacetsFactory =
      await ethers.getContractFactory("RestakerFacets");
    let restakerFacetsContract = await restakerFacetsFactory
      .connect(l2owner)
      .deploy(
        l2owner.getAddress(),
        eigenPodManagerMockContract.target,
        delegationManagerMockContract.target,
        {
          gasLimit: l2GasLimit,
        },
      );
    restakerFacetsContract = await restakerFacetsContract.waitForDeployment();
    log("restakerFacetsContract.address:", restakerFacetsContract.target);

    const restakerFactory = await ethers.getContractFactory("Restaker");
    let restakerContract = await restakerFactory.connect(l2owner).deploy({
      gasLimit: l2GasLimit,
    });
    restakerContract = await restakerContract.waitForDeployment();
    log("restakerContract.address:", restakerContract.target);
    await sleep(1000);

    upgradeableBeaconContract = await upgradeableBeaconFactory
      .connect(l2owner)
      .deploy(restakerContract.target, await l2owner.getAddress(), {
        gasLimit: l2GasLimit,
      });
    upgradeableBeaconContract =
      await upgradeableBeaconContract.waitForDeployment();
    log("upgradeableBeaconContract.address:", upgradeableBeaconContract.target);

    const restakerDeployerFactory =
      await ethers.getContractFactory("RestakerDeployer");
    let restakerDeployerContract = await restakerDeployerFactory
      .connect(l2owner)
      .deploy(upgradeableBeaconContract.target, restakerFacetsContract.target, {
        gasLimit: l2GasLimit,
      });
    restakerDeployerContract =
      await restakerDeployerContract.waitForDeployment();
    log("restakerDeployerContract.address:", restakerDeployerContract.target);

    let setRestakerDeployerTx =
      await protocolConfigContract.setRestakerDeployer(
        restakerDeployerContract.target,
      );
    await setRestakerDeployerTx.wait();

    const transferOwnershipTx =
      await erc20TokenFactoryContract.transferOwnership(
        restakerGatewayContract.target,
      );
    await transferOwnershipTx.wait();

    let addRestakerTx =
      await restakingPoolContract.addRestaker(RESTAKER_PROVIDER);
    await addRestakerTx.wait();

    return [
      restakerGatewayContract,
      restakingPoolContract,
      liquidityTokenContract,
      erc20TokenFactoryContract,
      erc20PeggedTokenContract,
    ];
  }

  async function SetUpL1Restaker(bridgeAddress) {
    let l1owner = ctxL1.owner();

    const peggedTokenFactory =
      await ethers.getContractFactory("ERC20PeggedToken");
    let peggedTokenContract = await peggedTokenFactory
      .connect(l1owner)
      .deploy();
    peggedTokenContract = await peggedTokenContract.waitForDeployment();

    const erc20TokenFactoryFactory =
      await ethers.getContractFactory("ERC20TokenFactory");
    let erc20TokenFactoryContract = await erc20TokenFactoryFactory
      .connect(l1owner)
      .deploy(peggedTokenContract.target);
    erc20TokenFactoryContract =
      await erc20TokenFactoryContract.waitForDeployment();

    const restakerGatewayFactory =
      await ethers.getContractFactory("RestakerGateway");
    let restakerGatewayContract = await restakerGatewayFactory
      .connect(l1owner)
      .deploy(
        bridgeAddress,
        "0x0000000000000000000000000000000000000000",
        erc20TokenFactoryContract.target,
      );
    restakerGatewayContract = await restakerGatewayContract.waitForDeployment();

    const transferOwnershipTx =
      await erc20TokenFactoryContract.transferOwnership(
        restakerGatewayContract.target,
      );
    await transferOwnershipTx.wait();

    return [
      restakerGatewayContract,
      erc20TokenFactoryContract,
      peggedTokenContract,
    ];
  }

  async function SetUpChain(ctx, withRollup) {
    log(`${ctx.networkName}: SetUpChain withRollup=${withRollup}`);

    let owner = ctx.owner();

    const erc20PeggedTokenFactory =
      await ethers.getContractFactory("ERC20PeggedToken");
    let erc20PeggedTokenContract = await erc20PeggedTokenFactory
      .connect(owner)
      .deploy();
    erc20PeggedTokenContract =
      await erc20PeggedTokenContract.waitForDeployment();
    log("erc20PeggedTokenContract.address:", erc20PeggedTokenContract.target);

    const bridgeFactory = await ethers.getContractFactory("Bridge");
    const ownerAddresses = await ctx.listAddresses();

    let rollupAddress = "0x0000000000000000000000000000000000000000";
    if (withRollup) {
      const VerifierContract = await ethers.getContractFactory("VerifierMock");

      let verifier = await VerifierContract.deploy();
      const rollupFactory = await ethers.getContractFactory("Rollup");
      const vkKey =
        "0x00612f9d5a388df116872ff70e36bcb86c7e73b1089f32f68fc8e0d0ba7861b7";
      const genesisHash =
        "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";
      rollupContract = await rollupFactory
        .connect(owner)
        .deploy(
          owner.address,
          0,
          0,
          0,
          verifier.target,
          vkKey,
          genesisHash,
          "0x0000000000000000000000000000000000000000",
          1,
          100,
        );
      rollupAddress = rollupContract.target;
      log("rollupAddress:", rollupAddress);
    }

    await sleep(1000);
    let bridgeContract = await bridgeFactory
      .connect(owner)
      .deploy(ownerAddresses[0], rollupAddress, 100);
    bridgeContract = await bridgeContract.waitForDeployment();
    log("bridgeContract.address:", bridgeContract.target);

    await sleep(1000);
    if (withRollup) {
      let setBridgeTx = await rollupContract.setBridge(bridgeContract.target);
      await setBridgeTx.wait();
    }

    const erc20TokenFactoryFactory =
      await ethers.getContractFactory("ERC20TokenFactory");
    let erc20TokenFactoryContract = await erc20TokenFactoryFactory
      .connect(owner)
      .deploy(erc20PeggedTokenContract.target);
    erc20TokenFactoryContract =
      await erc20TokenFactoryContract.waitForDeployment();
    log("erc20TokenFactoryContract.address:", erc20TokenFactoryContract.target);
    await sleep(1000);

    const erc20GatewayFactory = await ethers.getContractFactory("ERC20Gateway");
    let erc20GatewayContract = await erc20GatewayFactory
      .connect(owner)
      .deploy(bridgeContract.target, erc20TokenFactoryContract.target, {
        value: ethers.parseEther("1000"),
      });

    log(
      "erc20TokenFactoryContract.owner:",
      await erc20TokenFactoryContract.owner(),
    );
    await sleep(1000);
    const transferOwnershipTx =
      await erc20TokenFactoryContract.transferOwnership(
        erc20GatewayContract.target,
      );
    await transferOwnershipTx.wait();
    log(
      "erc20TokenFactoryContract.owner:",
      await erc20TokenFactoryContract.owner(),
    );

    erc20GatewayContract = await erc20GatewayContract.waitForDeployment();
    log("erc20GatewayContract.address:", erc20GatewayContract.target);

    return [
      erc20GatewayContract,
      bridgeContract,
      erc20PeggedTokenContract.target,
      erc20TokenFactoryContract.target,
    ];
  }

  it("Compare pegged token addresses", async function () {
    let t1 = await l2GatewayContract.computePeggedTokenAddress(
      l1TokenContract.target,
    );
    let t2 = await l1GatewayContract.computeOtherSidePeggedTokenAddress(
      l1TokenContract.target,
    );
    expect(t1).to.equal(t2);
  });

  it("Bridging tokens between to contracts", async function () {
    let l2Addresses = await ctxL2.listAddresses();

    const approveTx = await l1TokenContract.approve(
      l2GatewayContract.target,
      100,
    );
    await approveTx.wait();

    log("Token send");

    let liquidityTokenAmount = await liquidityTokenContract.convertToAmount(1);
    log(
      "liquidityTokenContract.address:",
      liquidityTokenContract.target,
      "liquidityTokenAmount:",
      liquidityTokenAmount,
    );
    for (let v of [ctxL1, ctxL2]) {
      await v.printDebugInfoAsync();
    }
    const [ownerL1] = ctxL1.accounts;
    const sendRestakedTokensTx =
      await l2RestakerGatewayContract.sendRestakedTokens(ownerL1.address, {
        value: "32000000000000000000",
        gasLimit: l2GasLimit,
      });
    let sendRestakedTokensTxReceipt = await sendRestakedTokensTx.wait();
    log("liquidityTokenContract.address:", liquidityTokenContract.target);

    const l1BridgeSentMessageEvents = await l2BridgeContract.queryFilter(
      "SentMessage",
      sendRestakedTokensTxReceipt.blockNumber,
    );

    expect(l1BridgeSentMessageEvents.length).to.equal(1);

    const sentEvent = l1BridgeSentMessageEvents[0];

    let sendMessageHash = sentEvent.args["messageHash"];

    log("sendMessageHash:", sendMessageHash);
    log("sentEvent:", sentEvent);

    const receiveMessageTx = await l1BridgeContract.receiveMessage(
      sentEvent.args["sender"],
      sentEvent.args["to"],
      sentEvent.args["value"],
      sentEvent.args["chainId"].toString(),
      sentEvent.args["blockNumber"],
      sentEvent.args["nonce"],
      sentEvent.args["data"],
      {
        gasLimit: l1GasLimit,
      },
    );
    await receiveMessageTx.wait();

    log(`receivedMessageEvents started`);
    const receivedMessageEvents = await l1BridgeContract.queryFilter(
      "ReceivedMessage",
      receiveMessageTx.blockNumber,
    );
    const gatewayEvents = await l1RestakerGatewayContract.queryFilter(
      "ReceivedTokens",
      receiveMessageTx.blockNumber,
    );

    log("receivedMessageEvents:", receivedMessageEvents);
    expect(receivedMessageEvents.length).to.equal(1);
    log("gatewayEvents:", gatewayEvents);
    expect(gatewayEvents.length).to.equal(1);

    log(`batchDeposit started`);
    let batchDepositTx = await restakingPoolContract.batchDeposit(
      RESTAKER_PROVIDER,
      [
        "0xb8ed0276c4c631f3901bafa668916720f2606f58e0befab541f0cf9e0ec67a8066577e9a01ce58d4e47fba56c516f25b",
      ],
      [
        "0x927b16171b51ca4ccab59de07ea20dacc33baa0f89f06b6a762051cac07233eb613a6c272b724a46b8145850b8851e4a12eb470bfb140e028ae0ac794f3a890ec4fac33910d338343f059d93a6d688238510c147f155d984de7c01daa0d3241b",
      ],
      ["0x50021ea68edb12aaa54fc8a2706b2f4b1d35d1406512fc6de230e0ea0391cf97"],
      {
        gasLimit: l2GasLimit,
      },
    );
    await batchDepositTx.wait();

    log(`claimRestaker started`);
    let claimRestakerTx = await restakingPoolContract.claimRestaker(
      RESTAKER_PROVIDER,
      0,
      {
        gasLimit: l2GasLimit,
      },
    );
    await claimRestakerTx.wait();

    const erc20PeggedTokenArtifact =
      await artifacts.readArtifact("ERC20PeggedToken");
    const erc20PeggedTokenAbi = erc20PeggedTokenArtifact.abi;

    log(`computePeggedTokenAddress started`);
    let peggedTokenAddress =
      await l1RestakerGatewayContract.computePeggedTokenAddress(
        liquidityTokenContract.target,
        {
          gasLimit: l1GasLimit,
        },
      );
    let peggedTokenContract = new ethers.Contract(
      peggedTokenAddress,
      erc20PeggedTokenAbi,
      ownerL1,
    );
    log("peggedTokenAddress:", peggedTokenAddress);
    let tokenAmount = await peggedTokenContract.balanceOf(ownerL1.address);
    log("tokenAmount:", tokenAmount);
    const sendUnstakingTokensTx =
      await l1RestakerGatewayContract.sendUnstakingTokens(l2Addresses[3], 10, {
        gasLimit: l1GasLimit,
      });
    log("liquidityTokenContract.address:", liquidityTokenContract.target);

    let sendBackReceipt = await sendUnstakingTokensTx.wait();

    const sentMessageEvents = await l1BridgeContract.queryFilter(
      "SentMessage",
      sendBackReceipt.blockNumber,
    );

    expect(sentMessageEvents.length).to.equal(1);
    let messageHash = sentMessageEvents[0].args.messageHash;

    log(`sentMessageEvents:`, sentMessageEvents);
    const sentMessageEvent = sentMessageEvents[0];

    let deposits = Buffer.from(sendMessageHash.substring(2), "hex");
    log(deposits);

    let depositHash = ethers.keccak256(messageHash);

    const commitmentBatch = [
      {
        previousBlockHash:
          "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        blockHash: sendRestakedTokensTxReceipt.blockHash,
        withdrawalHash: sentMessageEvent.args.messageHash,
        depositHash:
          "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
      },
    ];
    const depositsInBlock = [];

    let nextBatchIndex = await rollupContract.nextBatchIndex();
    console.log(nextBatchIndex, depositsInBlock, commitmentBatch);
    const acceptNextProofTx = await rollupContract.acceptNextBatch(
      nextBatchIndex,
      commitmentBatch,
      depositsInBlock,
      {
        gasLimit: 30_000_000,
      },
    );
    await acceptNextProofTx.wait();

    const receiveMessageWithProofTx =
      await l2BridgeContract.receiveMessageWithProof(
        nextBatchIndex,
        commitmentBatch[0],
        sentMessageEvent.args["sender"],
        sentMessageEvent.args["to"],
        sentMessageEvent.args["value"].toString(),
        sentMessageEvent.args["chainId"].toString(),
        sentMessageEvent.args["blockNumber"].toString(),
        sentMessageEvent.args["nonce"].toString(),
        sentMessageEvent.args["data"],
        {
          nonce: 0,
          proof: "0x",
        },
        {
          nonce: 0,
          proof: "0x",
        },
        {
          gasLimit: 30_000_000,
        },
      );
    let receiveBackMessage = await receiveMessageWithProofTx.wait();

    const bridgeBackEvents = await l2BridgeContract.queryFilter(
      "ReceivedMessage",
      receiveBackMessage.blockNumber,
    );
    const gatewayBackEvents = await l2RestakerGatewayContract.queryFilter(
      "TokensUnstaked",
      receiveBackMessage.blockNumber,
    );

    const events = await l2BridgeContract.queryFilter(
      "RollbackMessage",
      receiveBackMessage.blockNumber,
    );

    console.log(
      receiveBackMessage,
      bridgeBackEvents,
      gatewayBackEvents,
      events,
    );

    log("bridgeBackEvents:", bridgeBackEvents);
    expect(bridgeBackEvents.length).to.equal(1);
    log("gatewayBackEvents:", gatewayBackEvents);
    expect(gatewayBackEvents.length).to.equal(1);

    let distributeUnstakesTx = await restakingPoolContract.distributeUnstakes({
      gasLimit: l2GasLimit,
    });
    await distributeUnstakesTx.wait();
  });
});
