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

    const contractWithSigner = tokenFactory.connect(accounts[0]);
    const computeAddress = await contractWithSigner.computePeggedTokenAddress(
      "0x1111111111111111111111111111111111111111",
      "0x2222222222222222222222222222222222222222",
    );

    expect(computeAddress).equal("0xFc8c1cFe7C613864aa89eCa751B8D861c6D097ea");
  });

  it("deployPeggedToken", async function () {
    const accounts = await hre.ethers.getSigners();

    const contractWithSigner = tokenFactory.connect(accounts[0]);

    const deployTx = await contractWithSigner.deployPeggedToken(
      "0x1111111111111111111111111111111111111111",
      "0x2222222222222222222222222222222222222222",
    );

    await deployTx.wait();

    let events = await tokenFactory.queryFilter(
      "TokenDeployed",
      deployTx.blockNumber,
    );

    expect(events.length).to.equal(1);

    let peggedAddress = events[0].args._peggedToken;

    const tokenArtifact = await artifacts.readArtifact("ERC20PeggedToken");
    const tokenAbi = tokenArtifact.abi;

    // Connect to deployed Token contract
    let tokenContract = new ethers.Contract(
      peggedAddress,
      tokenAbi,
      await ethers.provider.getSigner(),
    );

    let initTx = await tokenContract.initialize(
      "Token",
      "Symbol",
      16,
      "0x1111111111111111111111111111111111111111",
      "0x2222222222222222222222222222222222222222",
    );

    await initTx.wait();

    let [gateway, origin] = await tokenContract.getOrigin();

    expect(gateway).equal("0x1111111111111111111111111111111111111111");
    expect(origin).equal("0x2222222222222222222222222222222222222222");
  });
});
