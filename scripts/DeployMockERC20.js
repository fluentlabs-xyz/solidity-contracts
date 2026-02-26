/**
 * Deploy MockERC20Token on the current network (e.g. Sepolia for deposit token).
 *
 * Usage:
 *   npx hardhat run scripts/DeployMockERC20.js --network sepoliaEth
 *   MOCK_TOKEN_SUPPLY_TARGET=0x... npx hardhat run scripts/DeployMockERC20.js --network sepoliaEth
 *
 * Env (optional): MOCK_TOKEN_NAME, MOCK_TOKEN_SYMBOL, MOCK_TOKEN_SUPPLY, MOCK_TOKEN_SUPPLY_TARGET
 * Default: name="Mock Deposit Token", symbol="MDT", supply=1e6*1e18, target=deployer
 */
const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  const name = process.env.MOCK_TOKEN_NAME || "Mock Deposit Token";
  const symbol = process.env.MOCK_TOKEN_SYMBOL || "MDT";
  const supply = process.env.MOCK_TOKEN_SUPPLY ? BigInt(process.env.MOCK_TOKEN_SUPPLY) : ethers.parseEther("1000000");
  const supplyTarget = process.env.MOCK_TOKEN_SUPPLY_TARGET || deployer.address;

  const MockERC20 = await ethers.getContractFactory("MockERC20Token");
  const token = await MockERC20.deploy(name, symbol, supply, supplyTarget);
  await token.waitForDeployment();
  const address = await token.getAddress();
  console.log("MockERC20Token:", address);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
