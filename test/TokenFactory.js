const { expect } = require("chai");
const { BigNumber } = require("ethers");
const { address } = require("hardhat/internal/core/config/config-validation");

describe("TokenFactory", function () {
  let tokenFactory;

  before(async function () {
    const Token = await ethers.getContractFactory("ERC20PeggedToken");
    let token = await Token.deploy(); // Adjust initial supply as needed
    token = await token.waitForDeployment();

    const TokenFactoryContract =
      await ethers.getContractFactory("ERC20TokenFactory");
    tokenFactory = await TokenFactoryContract.deploy(token.target);
    tokenFactory = await tokenFactory.waitForDeployment();
  });

  it("computePeggedTokenAddress", async function () {
    const accounts = await hre.ethers.getSigners();
    const gateway = "0x1111111111111111111111111111111111111111";
    const originToken = "0x2222222222222222222222222222222222222222";

    const contractWithSigner = tokenFactory.connect(accounts[0]);
    const computeAddress = await contractWithSigner.computePeggedTokenAddress(
      gateway,
      originToken,
    );

    expect(ethers.isAddress(computeAddress)).to.equal(true);
    expect(computeAddress).to.not.equal(ethers.ZeroAddress);
  });

  it("deployPeggedToken", async function () {
    const accounts = await hre.ethers.getSigners();
    const gateway = "0x1111111111111111111111111111111111111111";
    const originToken = "0x2222222222222222222222222222222222222222";

    const contractWithSigner = tokenFactory.connect(accounts[0]);
    const computedAddress = await tokenFactory.computePeggedTokenAddress(
      gateway,
      originToken,
    );

    const deployTx = await contractWithSigner.deployToken(
      gateway,
      originToken,
    );

    await deployTx.wait();

    let events = await tokenFactory.queryFilter(
      "TokenDeployed",
      deployTx.blockNumber,
    );

    expect(events.length).to.equal(1);

    let peggedAddress = events[0].args[1];

    const tokenArtifact = await artifacts.readArtifact("ERC20PeggedToken");
    const tokenAbi = tokenArtifact.abi;

    // Connect to deployed Token contract
    let tokenContract = new ethers.Contract(
      peggedAddress,
      tokenAbi,
      await ethers.provider.getSigner(),
    );

    expect(peggedAddress).to.equal(computedAddress);

    let initTx = await tokenContract.initialize(
      "Token",
      "Symbol",
      16,
      gateway,
      originToken,
    );

    await initTx.wait();

    let [gatewayFromToken, originFromToken] = await tokenContract.getOrigin();

    expect(gatewayFromToken).to.equal(gateway);
    expect(originFromToken).to.equal(originToken);
  });
});
