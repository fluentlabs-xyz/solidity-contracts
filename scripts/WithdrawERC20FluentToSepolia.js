/**
 * Withdraw pegged ERC20 from Fluent dev to Sepolia: burn pegged tokens on L2 and send message to L1.
 * Run on Fluent. Recipient will receive native tokens on Sepolia after relayer submits receiveMessage on L1.
 *
 * Usage:
 *   L2_GATEWAY_ADDRESS=0x... ORIGIN_TOKEN_ADDRESS=0x... RECIPIENT_ADDRESS=0x... AMOUNT=500 \
 *     npx hardhat run scripts/WithdrawERC20FluentToSepolia.js --network fluentDev
 *
 * Env: L2_GATEWAY_ADDRESS, ORIGIN_TOKEN_ADDRESS (L1 token address, e.g. MockERC20 on Sepolia),
 *      RECIPIENT_ADDRESS (L1 address to receive tokens), AMOUNT (default 500).
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
  const gatewayAddress = requireEnv("L2_GATEWAY_ADDRESS", process.env.L2_GATEWAY_ADDRESS);
  const originTokenAddress = requireEnv("ORIGIN_TOKEN_ADDRESS", process.env.ORIGIN_TOKEN_ADDRESS);
  const recipient = requireEnv("RECIPIENT_ADDRESS", process.env.RECIPIENT_ADDRESS);
  const amount = process.env.AMOUNT ? BigInt(process.env.AMOUNT) : 500n;

  const [signer] = await ethers.getSigners();
  const gateway = await ethers.getContractAt("ERC20Gateway", gatewayAddress, signer);

  const peggedTokenAddress = await gateway.computePeggedTokenAddress(originTokenAddress);
  const peggedToken = await ethers.getContractAt("ERC20PeggedToken", peggedTokenAddress, signer);
  const balance = await peggedToken.balanceOf(signer.address);
  if (balance < amount) {
    console.error("Insufficient pegged token balance:", balance.toString(), "required:", amount.toString());
    process.exit(1);
  }

  const sendTx = await gateway.sendTokens(peggedTokenAddress, recipient, amount);
  const receipt = await sendTx.wait();
  console.log("sendTokens (burn + message) tx:", receipt.hash);
  console.log("Withdraw done. Run the relayer to submit receiveMessage on Sepolia so", recipient, "receives native tokens.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
