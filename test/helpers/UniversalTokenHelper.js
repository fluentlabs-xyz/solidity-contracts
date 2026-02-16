const { ethers } = require("hardhat");

// Precompile address from UniversalTokenSDK
const UNIVERSAL_TOKEN_RUNTIME = "0x0000000000000000000000000000000000520008";

let deployHelper;

/**
 * Gets or deploys the UniversalTokenDeployHelper contract
 * @returns {Promise<Contract>} The deploy helper contract
 */
async function getDeployHelper() {
  if (!deployHelper) {
    const DeployHelper = await ethers.getContractFactory(
      "UniversalTokenDeployHelper"
    );
    deployHelper = await DeployHelper.deploy();
    await deployHelper.waitForDeployment();
  }
  return deployHelper;
}

/**
 * Deploys a Universal Token contract at a deterministic address using CREATE2
 * This simulates the precompile behavior for Hardhat testing
 * @param {string} salt - The salt for CREATE2 (as hex string or bytes32)
 * @param {string} name - Token name
 * @param {string} symbol - Token symbol
 * @param {number} decimals - Number of decimals
 * @param {bigint} initialSupply - Initial supply
 * @param {string} minter - Minter address
 * @param {string} pauser - Pauser address
 * @returns {Promise<{address: string, contract: Contract}>} The deployed token address and contract
 */
async function deployUniversalToken(
  salt,
  name,
  symbol,
  decimals,
  initialSupply,
  minter,
  pauser
) {
  const helper = await getDeployHelper();

  // Convert salt to bytes32 if it's a string
  let saltBytes32;
  if (typeof salt === "string") {
    if (salt.startsWith("0x")) {
      saltBytes32 = salt;
    } else {
      saltBytes32 = ethers.keccak256(ethers.toUtf8Bytes(salt));
    }
  } else {
    saltBytes32 = salt;
  }

  // Compute the address first
  const helperAddress = await helper.getAddress();
  const tokenAddress = await computeTokenAddress(
    helperAddress,
    saltBytes32,
    name,
    symbol,
    decimals,
    initialSupply,
    minter,
    pauser
  );

  // Check if already deployed
  const code = await ethers.provider.getCode(tokenAddress);
  if (code !== "0x") {
    const tokenContract = await ethers.getContractAt(
      "IUniversalToken",
      tokenAddress
    );
    return { address: tokenAddress, contract: tokenContract };
  }

  // Deploy the token using the helper
  const tx = await helper.deployToken(
    saltBytes32,
    name,
    symbol,
    decimals,
    initialSupply,
    minter,
    pauser
  );
  await tx.wait();

  const tokenContract = await ethers.getContractAt(
    "IUniversalToken",
    tokenAddress
  );

  return { address: tokenAddress, contract: tokenContract };
}

/**
 * Computes the address where a Universal Token would be deployed
 * @param {string} deployer - Address that will deploy the token (the helper contract)
 * @param {string} salt - The salt for CREATE2
 * @param {string} name - Token name (for bytecode computation)
 * @param {string} symbol - Token symbol (for bytecode computation)
 * @param {number} decimals - Number of decimals (for bytecode computation)
 * @param {bigint} initialSupply - Initial supply (for bytecode computation)
 * @param {string} minter - Minter address (for bytecode computation)
 * @param {string} pauser - Pauser address (for bytecode computation)
 * @returns {Promise<string>} The predicted token address
 */
async function computeTokenAddress(
  deployer,
  salt,
  name = "",
  symbol = "",
  decimals = 18,
  initialSupply = 0n,
  minter = ethers.ZeroAddress,
  pauser = ethers.ZeroAddress
) {
  // Convert salt to bytes32 if needed
  let saltBytes32;
  if (typeof salt === "string") {
    if (salt.startsWith("0x") && salt.length === 66) {
      saltBytes32 = salt;
    } else {
      saltBytes32 = ethers.keccak256(ethers.toUtf8Bytes(salt));
    }
  } else {
    saltBytes32 = salt;
  }

  // Get the UniversalToken creation bytecode with constructor args
  const UniversalToken = await ethers.getContractFactory("UniversalToken");
  const bytecode = UniversalToken.bytecode;
  const encodedArgs = ethers.AbiCoder.defaultAbiCoder().encode(
    ["string", "string", "uint8", "uint256", "address", "address"],
    [name, symbol, decimals, initialSupply, minter, pauser]
  );
  const creationBytecode = bytecode + encodedArgs.slice(2); // Remove 0x prefix

  // Compute CREATE2 address
  const bytecodeHash = ethers.keccak256(creationBytecode);
  const hash = ethers.keccak256(
    ethers.solidityPacked(
      ["bytes1", "address", "bytes32", "bytes32"],
      ["0xff", deployer, saltBytes32, bytecodeHash]
    )
  );
  return ethers.getAddress("0x" + hash.slice(-40));
}

/**
 * Gets a Universal Token contract interface
 * @param {string} tokenAddress - The token address
 * @returns {Promise<Contract>} The token contract interface
 */
async function getUniversalToken(tokenAddress) {
  return await ethers.getContractAt("IUniversalToken", tokenAddress);
}

module.exports = {
  deployUniversalToken,
  computeTokenAddress,
  getUniversalToken,
  getDeployHelper,
  UNIVERSAL_TOKEN_RUNTIME,
};
