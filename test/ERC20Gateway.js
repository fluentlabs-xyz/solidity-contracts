const { expect } = require("chai");
const { AbiCoder, BigNumber } = require("ethers");
const { address } = require("hardhat/internal/core/config/config-validation");

describe("ERC20Gateway", function () {
  let bridge;
  let erc20Gateway;
  let erc20GatewayAbi;
  let token;
  let tokenFactory;

  before(async function () {
    const PeggedToken = await ethers.getContractFactory("ERC20PeggedToken");
    let peggedToken = await PeggedToken.deploy(); // Adjust initial supply as needed
    peggedToken = await peggedToken.waitForDeployment();

    const BridgeContract = await ethers.getContractFactory("Bridge");
    const accounts = await hre.ethers.getSigners();
    bridge = await BridgeContract.deploy(
      accounts[0].address,
      accounts[1].address,
      0,
      "0x0000000000000000000000000000000000000001",
      "0x0000000000000000000000000000000000000002",
    );
    bridge = await bridge.waitForDeployment();

    const TokenFactoryContract =
      await ethers.getContractFactory("ERC20TokenFactory");
    tokenFactory = await TokenFactoryContract.deploy(peggedToken.target);
    tokenFactory = await tokenFactory.waitForDeployment();

    const ERC20GatewayContract =
      await ethers.getContractFactory("ERC20Gateway");
    erc20GatewayAbi = ERC20GatewayContract.interface.format();
    erc20Gateway = await ERC20GatewayContract.deploy(
      bridge.target,
      tokenFactory.target,
      {
        value: ethers.parseEther("1000"),
      },
    );

    const authTx = await tokenFactory.transferOwnership(erc20Gateway.target);
    await authTx.wait();

    const acceptTx = await erc20Gateway.acceptTokenFactory();
    await acceptTx.wait();

    const Token = await ethers.getContractFactory("MockERC20Token");
    token = await Token.deploy(
      "Mock Token",
      "TKN",
      ethers.parseEther("1000000"),
      accounts[0].address,
    ); // Adjust initial supply as needed
    token = await token.waitForDeployment();

    erc20Gateway = await erc20Gateway.waitForDeployment();

    await erc20Gateway.setOtherSide("0x1111111111111111111111111111111111111111", "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000");
  });

  it("Send tokens test", async function () {
    const accounts = await hre.ethers.getSigners();
    const tokenWithSigner = token.connect(accounts[0]);
    const approve_tx = await tokenWithSigner.approve(erc20Gateway.target, 100);
    await approve_tx.wait();

    const contractWithSigner = erc20Gateway.connect(accounts[0]);
    const origin_balance = await token.balanceOf(accounts[0].address);
    const origin_bridge_balance = await token.balanceOf(erc20Gateway.target);

    const send_tx = await contractWithSigner.sendTokens(
      token.target,
      accounts[3].address,
      100,
    );

    await send_tx.wait();

    const events = await bridge.queryFilter("SentMessage", send_tx.blockNumber);

    expect(events.length).to.equal(1);

    expect(events[0].args.sender).to.equal(erc20Gateway.target);

    const balance = await token.balanceOf(accounts[0].address);
    const bridge_balance = await token.balanceOf(erc20Gateway.target);

    expect(bridge_balance - origin_bridge_balance).to.be.eql(100n);
    expect(origin_balance - balance).to.be.eql(100n);
  });

  it("Receive tokens test", async function () {
    const accounts = await hre.ethers.getSigners();
    const contractWithSigner = bridge.connect(accounts[0]);

    const receiverAddress = await accounts[3].getAddress();

    const origin_balance =
      await hre.ethers.provider.getBalance(receiverAddress);

    const gatewayInterface = new ethers.Interface(erc20GatewayAbi);
    const _token = token.target;
    const _to = accounts[3].address;
    const _from = accounts[0].address;
    const _amount = 100;

    const functionSelector = gatewayInterface.getFunction(
      "receivePeggedTokens",
    ).selector;

    const peggedTokenAddress = await tokenFactory.computePeggedTokenAddress(
      erc20Gateway.target,
      token.target,
    );

    const tokenMetadata = {
      name: "MyToken",
      symbol: "MTK",
      decimals: 18,
    };

    const encodedTokenMetadata = AbiCoder.defaultAbiCoder().encode(
      ["string", "string", "uint8"],
      [tokenMetadata.symbol, tokenMetadata.name, tokenMetadata.decimals],
    );

    const _message =
      functionSelector +
      AbiCoder.defaultAbiCoder()
        .encode(
          ["address", "address", "address", "address", "uint256", "bytes"],
          [
            _token,
            peggedTokenAddress,
            _from,
            _to,
            _amount,
            encodedTokenMetadata,
          ],
        )
        .slice(2);

    const data = AbiCoder.defaultAbiCoder()
      .encode(
        [
          "address",
          "address",
          "uint256",
          "uint256",
          "uint256",
          "uint256",
          "bytes",
        ],
        [
          "0x1111111111111111111111111111111111111111",
          erc20Gateway.target,
          0,
          0,
          0,
          0,
          _message,
        ],
      )
      .slice(2);

    const inputBytes = Buffer.from(data, "hex");
    const hash = ethers.keccak256(inputBytes);

    const receive_tx = await contractWithSigner.receiveMessage(
      "0x1111111111111111111111111111111111111111",
      erc20Gateway.target,
      0,
      0,
      0,
      0,
      _message,
    );

    await receive_tx.wait();

    let events = await bridge.queryFilter(
      "ReceivedMessage",
      receive_tx.blockNumber,
    );

    expect(events.length).to.equal(1);
    expect(events[0].args.messageHash).to.equal(hash);
    expect(events[0].args.successfulCall).to.equal(true);

    const new_balance = await hre.ethers.provider.getBalance(receiverAddress);
    expect(new_balance - origin_balance).to.be.eql(0n);

    const tokenArtifact = await artifacts.readArtifact("ERC20PeggedToken");
    const tokenAbi = tokenArtifact.abi;

    let peggedTokenContract = new ethers.Contract(
      peggedTokenAddress,
      tokenAbi,
      await ethers.provider.getSigner(),
    );

    const balance = await peggedTokenContract.balanceOf(receiverAddress);

    expect(balance).to.be.eql(100n);

    try {
      const repeat_receive_tx = await contractWithSigner.receiveMessage(
        "0x1111111111111111111111111111111111111111",
        erc20Gateway.target,
        0,
        0,
        0,
        0,
        "0x",
      );

      await repeat_receive_tx.wait();
    } catch (error) {
      expect(error.toString()).to.equal(
        "Error: VM Exception while processing transaction: " +
          "reverted with custom error 'MessageReceivedOutOfOrder()'",
      );
    }
  });
});
