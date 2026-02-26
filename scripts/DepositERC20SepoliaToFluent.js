/**
 * Deposit MockERC20 from Sepolia to Fluent dev: approve L1 gateway and sendTokens.
 * Run on Sepolia. Recipient will receive pegged tokens on Fluent dev after relayer submits receiveMessage.
 *
 * Usage:
 *   L1_GATEWAY_ADDRESS=0x... MOCK_TOKEN_ADDRESS=0x... RECIPIENT_ADDRESS=0x... AMOUNT=1000 \
 *     npx hardhat run scripts/DepositERC20SepoliaToFluent.js --network sepoliaEth
 *
 * Env: L1_GATEWAY_ADDRESS, MOCK_TOKEN_ADDRESS, RECIPIENT_ADDRESS (required), AMOUNT (default 1000).
 */
const { ethers } = require("hardhat");

function requireEnv(name, value) {
  if (!value) {
    console.error("Missing env: " + name);
    process.exit(1);
  }
  return value;
}

async function main() {
  const gatewayAddress = requireEnv("L1_GATEWAY_ADDRESS", process.env.L1_GATEWAY_ADDRESS);
  const tokenAddress = requireEnv("MOCK_TOKEN_ADDRESS", process.env.MOCK_TOKEN_ADDRESS);
  const recipient = requireEnv("RECIPIENT_ADDRESS", process.env.RECIPIENT_ADDRESS);
  const amount = process.env.AMOUNT ? BigInt(process.env.AMOUNT) : 1000n;

  const [signer] = await ethers.getSigners();
  const token = await ethers.getContractAt("MockERC20Token", tokenAddress, signer);
  const gateway = await ethers.getContractAt("ERC20Gateway", gatewayAddress, signer);

  const approveTx = await token.approve(gatewayAddress, amount);
  await approveTx.wait();
  console.log("Approved", amount.toString(), "tokens for gateway. Tx:", approveTx.hash);

  const sendTx = await gateway.sendTokens(tokenAddress, recipient, amount);
  const receipt = await sendTx.wait();
  console.log("sendTokens tx:", receipt.hash);
  console.log("Deposit done. Run the relayer to submit receiveMessage on Fluent dev.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
