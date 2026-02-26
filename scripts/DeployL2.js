const { ethers } = require("hardhat");
const {vars} = require("hardhat/config");

async function main() {
  const provider_url = "https://rpc.dev1.fluentlabs.xyz/";
  // const provider_url = "http://127.0.0.1:8546/"

  let provider = new ethers.JsonRpcProvider(provider_url);

  const privateKey = vars.get("HOLESKY_PRIVATE_KEY");
  const signer = new ethers.Wallet(privateKey, provider);

  await deployL2(provider, signer);
}

async function deployL2(provider, signer) {
  const address = await signer.getAddress();
  console.log("Signer: ", address);

  const balanceWei = await provider.getBalance(address);

  console.log("Balance: ", balanceWei);

  const PeggedToken = await ethers.getContractFactory("ERC20PeggedToken");
  let peggedToken = await PeggedToken.connect(signer).deploy();
  peggedToken = await peggedToken.waitForDeployment();
  console.log("Pegged token: ", peggedToken.target);

  const BridgeContract = await ethers.getContractFactory("Bridge");

  let rollupAddress = "0x0000000000000000000000000000000000000000";
  let bridge = await BridgeContract.connect(signer).deploy(
    signer.getAddress(),
    rollupAddress,
  );
  bridge = await bridge.waitForDeployment();
  console.log("Bridge: ", bridge.target);

  const hre = require("hardhat");
  const TokenFactoryContract =
    await ethers.getContractFactory("ERC20TokenFactory");
  const deployerAddress = await signer.getAddress();
  let tokenFactory = await hre.upgrades.deployProxy(
    TokenFactoryContract,
    [deployerAddress, peggedToken.target],
    { kind: "transparent", initializer: "initialize" },
  );
  await tokenFactory.waitForDeployment();
  console.log("TokenFactory: ", tokenFactory.target);

  const ERC20GatewayContract = await ethers.getContractFactory("ERC20Gateway");
  let erc20Gateway = await ERC20GatewayContract.connect(signer).deploy(
    bridge.target,
    tokenFactory.target,
  );

  console.log("token factory owner: ", await tokenFactory.owner());
  const authTx = await tokenFactory.transferOwnership(erc20Gateway.target);
  await authTx.wait();
  console.log("token factory owner: ", await tokenFactory.owner());

  erc20Gateway = await erc20Gateway.waitForDeployment();
  console.log("Gateway: ", erc20Gateway.target);

  return {
    bridge: bridge.target,
    erc20Gateway: erc20Gateway.target,
    peggedToken: peggedToken.target,
    tokenFactory: tokenFactory.target,
  };
}

module.exports = deployL2;
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}
