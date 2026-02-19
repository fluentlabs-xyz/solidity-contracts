/**
 * Prints the deployment data for a Universal Token using UniversalTokenSDK encoding.
 * Params match the Rust example:
 *   TOKEN_NAME = "Bridged Token"
 *   TOKEN_SYMBOL = "BRIDGE"
 *   TOKEN_DECIMALS = 18
 *   token_initial_supply = 100
 */
const { ethers } = require("hardhat");
const {
  deployUniversalTokenFactoryWithLinking,
} = require("../test/helpers/UniversalTokenFactoryHelper");

function stringToBytes32(str) {
  const buf = Buffer.alloc(32);
  const strBuf = Buffer.from(str, "utf8");
  strBuf.copy(buf, 0, 0, Math.min(32, strBuf.length));
  return "0x" + buf.toString("hex");
}

async function main() {
  const TOKEN_NAME = "Bridged Token";
  const TOKEN_SYMBOL = "BRIDGE";
  const TOKEN_DECIMALS = 18;
  const TOKEN_INITIAL_SUPPLY = 100n;
  const MINTER = ethers.ZeroAddress;
  const PAUSER = ethers.ZeroAddress;

  // Deploy factory (uses SDK) and call getDeploymentDataAndHash
  const { factory } = await deployUniversalTokenFactoryWithLinking();

  const nameBytes32 = stringToBytes32(TOKEN_NAME);
  const symbolBytes32 = stringToBytes32(TOKEN_SYMBOL);

  const [deploymentData, bytecodeHash] = await factory.getDeploymentDataAndHash(
    nameBytes32,
    symbolBytes32,
    TOKEN_DECIMALS,
    TOKEN_INITIAL_SUPPLY,
    MINTER,
    PAUSER
  );

  console.log("UniversalTokenSDK deployment data for:");
  console.log("  Name:", TOKEN_NAME);
  console.log("  Symbol:", TOKEN_SYMBOL);
  console.log("  Decimals:", TOKEN_DECIMALS);
  console.log("  Initial supply:", TOKEN_INITIAL_SUPPLY.toString());
  console.log("  Minter:", MINTER);
  console.log("  Pauser:", PAUSER);
  console.log("");
  const len = deploymentData.startsWith("0x") ? (deploymentData.length - 2) / 2 : deploymentData.length / 2;
  console.log("deploymentData length:", len, "bytes (0x" + len.toString(16) + ")");
  console.log("bytecodeHash:", bytecodeHash);
  console.log("");
  console.log("deploymentData (full hex):");
  console.log(deploymentData);
  console.log("");
  console.log("--- For Rust comparison: raw bytes as hex (no 0x) ---");
  console.log(deploymentData.replace(/^0x/, ""));
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
