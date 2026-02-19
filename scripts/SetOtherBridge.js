/**
 * Set the other bridge address (for no-rollup deployment).
 * Usage: BRIDGE_ADDRESS=0x... OTHER_BRIDGE_ADDRESS=0x... npx hardhat run scripts/SetOtherBridge.js --network <network>
 */
const { ethers } = require("hardhat");

async function main() {
  const otherBridge = process.env.OTHER_BRIDGE_ADDRESS;
  const bridgeAddress = process.env.BRIDGE_ADDRESS;
  if (!otherBridge || !bridgeAddress) {
    console.error("Set env BRIDGE_ADDRESS (this chain) and OTHER_BRIDGE_ADDRESS (other chain).");
    process.exit(1);
  }
  const [signer] = await ethers.getSigners();
  const bridge = await ethers.getContractAt("FluentBridge", bridgeAddress, signer);
  const tx = await bridge.setOtherBridge(otherBridge);
  await tx.wait();
  console.log("setOtherBridge(", otherBridge, ") tx:", tx.hash);
}

main().catch((e) => { console.error(e); process.exit(1); });
