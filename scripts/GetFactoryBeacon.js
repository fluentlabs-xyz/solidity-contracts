/**
 * Print the beacon address of an ERC20TokenFactory (for use as OTHER_IMPL in SetGatewayOtherSide).
 * Create2 for pegged tokens uses the factory's beacon in the bytecode; gateways must use the
 * other side's factory beacon so L1 and L2 compute the same pegged token address.
 *
 * Usage:
 *   FACTORY_ADDRESS=0x... npx hardhat run scripts/GetFactoryBeacon.js --network fluentDev
 */
const { ethers } = require("hardhat");

async function main() {
  const factoryAddress = process.env.FACTORY_ADDRESS;
  if (!factoryAddress) {
    console.error("Set FACTORY_ADDRESS (ERC20TokenFactory on this chain).");
    process.exit(1);
  }
  const factory = await ethers.getContractAt("ERC20TokenFactory", factoryAddress);
  const beacon = await factory.beacon();
  console.log("ERC20TokenFactoryBeacon:", beacon);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
