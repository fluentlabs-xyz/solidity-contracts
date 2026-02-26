/**
 * Verify all Sepolia-deployed contracts on Etherscan.
 * Set ETHERSCAN_API_KEY in .env. Addresses below are from deploy-sepolia-fluent-devnet.sh output.
 *
 * Usage: npx hardhat run scripts/VerifySepolia.js --network sepoliaEth
 *
 * Optional env to override addresses: L1_BLOCK_ORACLE, L1_BRIDGE, L1_PEGGED_IMPL, L1_FACTORY, L1_GATEWAY, MOCK_TOKEN
 *
 * Ref: https://docs.etherscan.io/contract-verification/verify-with-hardhat
 * Etherscan API V2 is required; full scripted verify works with Hardhat 3 + @nomicfoundation/hardhat-verify 3.x.
 * If verification fails (V1 deprecated), verify manually at https://sepolia.etherscan.io (Verify Contract / Verify Proxy).
 */
const hre = require("hardhat");

const EIP1967_IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

const DEFAULT_ADDRESSES = {
  L1_BLOCK_ORACLE: "0x49526bf0CD5aD66104d091Be707F7C22E361c6Bc",
  L1_BRIDGE: "0xe0Cf1dFAF870517876e48102A50248CcA8F6eA27",
  L1_PEGGED_IMPL: "0x5c96D66842687EB3e3d9b658c8E0636F78DE7F66",
  L1_FACTORY: "0xD75dB0Dfac9Ca3B4aF7005220f1fDFC0daa960C9",
  L1_GATEWAY: "0xf4c45A9A69ebEC331b89a4d24b7903A8F2651F5B",
  MOCK_TOKEN: "0xE09CAC803c4a99FB94C891f64663B5656b2F261d",
};

async function getImplementationAddress(proxyAddress) {
  const slot = await hre.network.provider.request({
    method: "eth_getStorageAt",
    params: [proxyAddress, EIP1967_IMPL_SLOT, "latest"],
  });
  return "0x" + (slot.slice(-40));
}

async function verify(name, address, constructorArguments = [], contractPath = null) {
  try {
    const opts = { address };
    if (constructorArguments.length) opts.constructorArguments = constructorArguments;
    if (contractPath) opts.contract = contractPath;
    await hre.run("verify:verify", opts);
    console.log("Verified:", name, address);
  } catch (e) {
    if (e.message && e.message.includes("Already Verified")) {
      console.log("Already verified:", name, address);
    } else {
      console.error("Failed", name, address, e.message);
    }
  }
}

async function main() {
  const L1BlockOracle = process.env.L1_BLOCK_ORACLE || DEFAULT_ADDRESSES.L1_BLOCK_ORACLE;
  const L1Bridge = process.env.L1_BRIDGE || DEFAULT_ADDRESSES.L1_BRIDGE;
  const L1PeggedImpl = process.env.L1_PEGGED_IMPL || DEFAULT_ADDRESSES.L1_PEGGED_IMPL;
  const L1Factory = process.env.L1_FACTORY || DEFAULT_ADDRESSES.L1_FACTORY;
  const L1Gateway = process.env.L1_GATEWAY || DEFAULT_ADDRESSES.L1_GATEWAY;
  const MockToken = process.env.MOCK_TOKEN || DEFAULT_ADDRESSES.MOCK_TOKEN;

  if (!process.env.ETHERSCAN_API_KEY) {
    console.error("Set ETHERSCAN_API_KEY in .env");
    process.exit(1);
  }

  console.log("Verifying contracts on Sepolia...\n");

  await verify("L1BlockOracle", L1BlockOracle);

  await verify("ERC20PeggedToken (impl)", L1PeggedImpl);

  await verify(
    "MockERC20Token",
    MockToken,
    ["Mock Deposit Token", "MDT", "1000000000000000000000000", "0x1C92DffBCe76670F69007F22A54e31ff3Ab45d5E"]
  );

  const FluentBridgeImpl = await getImplementationAddress(L1Bridge);
  await verify("FluentBridge (impl)", FluentBridgeImpl);

  const ERC20TokenFactoryImpl = await getImplementationAddress(L1Factory);
  await verify("ERC20TokenFactory (impl)", ERC20TokenFactoryImpl);

  const ERC20GatewayImpl = await getImplementationAddress(L1Gateway);
  await verify("ERC20Gateway (impl)", ERC20GatewayImpl);

  console.log("\nDone. Proxies (FluentBridge, ERC20TokenFactory, ERC20Gateway) can be linked on Etherscan via 'Verify Proxy' using the implementation addresses above.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
