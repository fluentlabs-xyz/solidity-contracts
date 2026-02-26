const { ethers } = require("hardhat");
const {vars} = require("hardhat/config");

async function main() {
  const provider_url = "https://rpc.dev1.fluentlabs.xyz/";
  // const provider_url = "http://127.0.0.1:8546/"

  let provider = new ethers.JsonRpcProvider(provider_url);

  const privateKey = vars.get("HOLESKY_PRIVATE_KEY");
  const signer = new ethers.Wallet(privateKey, provider);

  const bridgeAddress = "0x492bF40bbd967fF54af052e8364D83Ae509436b1";

  console.log("Signer: ", signer.target);

  await deployRestakerL2(provider, signer, bridgeAddress);
}

async function deployRestakerL2(provider, l2Signer, bridgeAddress) {
  const PeggedToken = await ethers.getContractFactory("ERC20PeggedToken");
  let peggedToken = await PeggedToken.connect(l2Signer).deploy();
  peggedToken = await peggedToken.waitForDeployment();

  console.log("Pegged token: ", peggedToken.target);

  const hre = require("hardhat");
  const TokenFactoryContract =
    await ethers.getContractFactory("ERC20TokenFactory");
  let tokenFactory = await hre.upgrades.deployProxy(
    TokenFactoryContract,
    [await l2Signer.getAddress(), peggedToken.target],
    { kind: "transparent", initializer: "initialize" },
  );
  await tokenFactory.waitForDeployment();

  console.log("Token factory: ", tokenFactory.target);
  const RestakerGateway = await ethers.getContractFactory("RestakerGateway");

  let restakerGateway = await RestakerGateway.connect(l2Signer).deploy(
    bridgeAddress,
    "0x0000000000000000000000000000000000000000",
    tokenFactory.target,
  );
  restakerGateway = await restakerGateway.waitForDeployment();

  console.log("Restaker gateway: ", restakerGateway.target);

  const authTx = await tokenFactory.transferOwnership(restakerGateway.target);
  await authTx.wait();

  return {
    restakerGateway: restakerGateway.target,
    tokenFactory: tokenFactory.target,
    peggedToken: peggedToken.target,
  };
}

module.exports = deployRestakerL2;

if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}
