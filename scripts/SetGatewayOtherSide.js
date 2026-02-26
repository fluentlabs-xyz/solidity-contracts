/**
 * Set the other gateway and factory on the ERC20 gateway (for cross-chain pegged tokens).
 * OTHER_IMPL must be the **other side's ERC20TokenFactory beacon address** (not the token
 * implementation), so Create2 pegged-token addresses match. Get it via GetFactoryBeacon.js.
 *
 * Usage:
 *   GATEWAY_ADDRESS=0x... OTHER_GATEWAY=0x... OTHER_IMPL=0x... OTHER_FACTORY=0x... \
 *     npx hardhat run scripts/SetGatewayOtherSide.js --network sepoliaEth
 */
const { ethers } = require("hardhat");

async function main() {
  const gatewayAddress = process.env.GATEWAY_ADDRESS;
  const otherGateway = process.env.OTHER_GATEWAY;
  const otherImpl = process.env.OTHER_IMPL;
  const otherFactory = process.env.OTHER_FACTORY;

  if (!gatewayAddress || !otherGateway || !otherImpl || !otherFactory) {
    console.error("Set GATEWAY_ADDRESS, OTHER_GATEWAY, OTHER_IMPL, OTHER_FACTORY.");
    process.exit(1);
  }

  const [signer] = await ethers.getSigners();
  const gateway = await ethers.getContractAt("ERC20Gateway", gatewayAddress, signer);
  const tx = await gateway.setOtherSide(otherGateway, otherImpl, otherFactory);
  await tx.wait();
  console.log("setOtherSide(", otherGateway, ",", otherImpl, ",", otherFactory, ") tx:", tx.hash);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
