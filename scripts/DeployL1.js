const { ethers } = require("hardhat");
const { BigNumber } = require("ethers");
const {vars} = require("hardhat/config");

async function main() {
  let provider_url = "https://rpc.sepolia.org/";
  // "https://eth-sepolia.g.alchemy.com/v2/DBpiq0grreNG4r0wdvAUCfdGJswhIPhk";
  // const provider_url = "http://127.0.0.1:8545/";

  const privateKey = vars.get("HOLESKY_PRIVATE_KEY");
  let provider = new ethers.JsonRpcProvider(provider_url);

  let signer = new ethers.Wallet(privateKey, provider);
  // signer = provider.getSigner()

  await deployL1(provider, signer);
}

async function deployL1(provider, signer) {
  const address = await signer.getAddress();
  console.log("Signer: ", address);

  const balanceWei = await provider.getBalance(address);

  console.log("Balance: ", balanceWei);

  let awaiting = [];

  const Token = await ethers.getContractFactory("MockERC20Token");
  let l1Token = await Token.connect(signer).deploy(
    "Mock Token",
    "TKN",
    ethers.parseEther("1000000"),
    await signer.getAddress(),
  );
  l1Token = await l1Token.waitForDeployment();

  console.log("L1 token: ", l1Token.target);

  const PeggedToken = await ethers.getContractFactory("ERC20PeggedToken");
  let peggedToken = await PeggedToken.connect(signer).deploy();
  peggedToken = await peggedToken.waitForDeployment();

  // console.log("Contract: ", tx);

  // let peggedToken = await PeggedToken.connect(signer).attach("0x6Ff08946Cef705D7bBC5deef4E56004e2365979f");
  console.log("Pegged token: ", peggedToken.target);

  const RollupContract = await ethers.getContractFactory("Rollup");
  let rollup = await RollupContract.connect(signer).deploy();
  rollup = await rollup.waitForDeployment();

  // let rollup = await RollupContract.connect(signer).attach("0xb592Ed460f5Ab1b2eF874bE5e3d0FbE6950127Da");

  let rollupAddress = rollup.target;
  console.log("Rollup address: ", rollupAddress);

  const BridgeContract = await ethers.getContractFactory("Bridge");
  let bridge = await BridgeContract.connect(signer).deploy(
    signer.getAddress(),
    rollupAddress,
  );
  bridge = await bridge.waitForDeployment();

  // let bridge = await BridgeContract.connect(signer).attach("0xf70f7cADD71591e96BD696716A4A2bA6286c82e8");
  console.log("Bridge: ", bridge.target);

  const hre = require("hardhat");
  const TokenFactoryContract =
    await ethers.getContractFactory("ERC20TokenFactory");

  let tokenFactory = await hre.upgrades.deployProxy(
    TokenFactoryContract,
    [address, peggedToken.target],
    { kind: "transparent", initializer: "initialize" },
  );
  await tokenFactory.waitForDeployment();
  console.log("TokenFactory: ", tokenFactory.target);

  const ERC20GatewayContract = await ethers.getContractFactory("ERC20Gateway");
  let erc20Gateway = await ERC20GatewayContract.connect(signer).deploy(
    bridge.target,
    tokenFactory.target,
    {
      gasLimit: 2000000,
    },
  );
  erc20Gateway = await erc20Gateway.waitForDeployment();
  console.log("Gateway: ", erc20Gateway.target);

  const authTx = await tokenFactory.transferOwnership(erc20Gateway.target);
  await authTx.wait();
  console.log("Transferred ownership");
  let setBridge = await rollup.setBridge(bridge.target);
  await setBridge.wait();

  // await Promise.all(awaiting)

  console.log("Gateway contracts deployed");

  return {
    bridge: bridge.target,
    erc20Gateway: erc20Gateway.target,
    rollup: rollup.target,
    peggedToken: peggedToken.target,
    tokenFactory: tokenFactory.target,
  };
}

module.exports = deployL1;

if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}
