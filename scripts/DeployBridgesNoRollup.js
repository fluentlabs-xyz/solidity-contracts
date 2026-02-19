/**
 * Deploy FluentBridge in no-rollup mode (no sequencer).
 * Run once per chain. Then set otherBridge on each bridge and run the relayer.
 *
 * Usage:
 *   npx hardhat run scripts/DeployBridgesNoRollup.js --network sepoliaEth
 *   npx hardhat run scripts/DeployBridgesNoRollup.js --network fluentDev
 *
 * Env (optional): RELAYER_ADDRESS - set as bridgeAuthority (default: deployer)
 */
const hre = require("hardhat");
const { ethers } = require("hardhat");
const { deployFluentBridgeProxy } = require("../test/helpers/FluentBridgeProxy");

const ZERO = "0x0000000000000000000000000000000000000000";

async function main() {
  const [deployer] = await ethers.getSigners();
  const bridgeAuthority = process.env.RELAYER_ADDRESS || deployer.address;
  const network = await ethers.provider.getNetwork();
  const chainId = Number(network.chainId);

  console.log("Network:", chainId, "Deployer:", deployer.address, "Bridge authority:", bridgeAuthority);

  // 1. Deploy L1BlockOracle (needed for init; unused when receiveMessageDeadline=0)
  const L1BlockOracle = await ethers.getContractFactory("L1BlockOracle");
  const oracle = await L1BlockOracle.connect(deployer).deploy();
  await oracle.waitForDeployment();
  console.log("L1BlockOracle:", await oracle.getAddress());

  // 2. Deploy FluentBridge with rollup=0 (no queue), deadline=0 (no rollback path)
  const { bridge } = await deployFluentBridgeProxy(
    ethers,
    deployer.address,
    bridgeAuthority,
    ZERO,           // rollup
    0,              // receiveMessageDeadline
    ZERO,           // otherBridge (set later)
    await oracle.getAddress()
  );
  await bridge.waitForDeployment();
  const bridgeAddress = await bridge.getAddress();
  console.log("FluentBridge:", bridgeAddress);

  console.log("\n--- Next steps ---");
  console.log("1. Deploy on the other chain (same script, other network).");
  console.log("2. Call bridge.setOtherBridge(<otherBridgeAddress>) on both bridges (as owner).");
  console.log("3. Run relayer: RELAYER_PRIVATE_KEY=<key> L1_BRIDGE_ADDRESS=... L2_BRIDGE_ADDRESS=... node relay/RelayNoRollup.js");
  console.log("\nExport for relayer:");
  if (chainId === 11155111) console.log("L1_BRIDGE_ADDRESS=" + bridgeAddress);
  else if (chainId === 20993n || chainId === 20993) console.log("L2_BRIDGE_ADDRESS=" + bridgeAddress);
  else console.log("BRIDGE_ADDRESS=" + bridgeAddress);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
