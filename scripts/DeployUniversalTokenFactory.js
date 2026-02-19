const { ethers } = require("hardhat");
const { deployUniversalTokenFactoryWithLinking } = require("../test/helpers/UniversalTokenFactoryHelper");

const FLUENT_DEV_CHAIN_ID = 20993;

async function main() {
    const [deployer] = await ethers.getSigners();
    const address = await deployer.getAddress();

    console.log("Deploying to Fluent Dev (chainId:", FLUENT_DEV_CHAIN_ID, ")");
    console.log("Deployer:", address);

    const balance = await ethers.provider.getBalance(address);
    console.log("Balance:", ethers.formatEther(balance), "ETH");

    // 1. Deploy UniversalTokenSDK + UniversalTokenFactory
    console.log("\n--- Deploying UniversalTokenFactory ---");
    const { factory, library } = await deployUniversalTokenFactoryWithLinking();
    const factoryAddress = await factory.getAddress();
    const libraryAddress = await library.getAddress();

    console.log("UniversalTokenSDK library:", libraryAddress);
    console.log("UniversalTokenFactory:", factoryAddress);

    // 2. Deploy a bridged token via deployBridgedTokenCreate2
    // Use unique L1 token: hash of factory address + timestamp to avoid "already deployed"
    // const salt = ethers.keccak256(ethers.toUtf8Bytes(factoryAddress + Date.now().toString()));
    const l1Token = "0x1111111111111111111111111111111111111111";
    const chainId = FLUENT_DEV_CHAIN_ID;
    const name = "Bridged Token";
    const symbol = "BRIDGE";
    const decimals = 18;
    const initialSupply = 100n * 10n ** 18n;
    const minter = ethers.ZeroAddress;
    const pauser = ethers.ZeroAddress;

    console.log("\n--- Deploying bridged token ---");
    console.log("L1 token:", l1Token);
    console.log("Name:", name, "| Symbol:", symbol);

    let tokenAddress;
    try {
        const tx = await factory.deployBridgedTokenCreate2(
            l1Token,
            chainId,
            name,
            symbol,
            decimals,
            initialSupply,
            minter,
            pauser,
            { gasLimit: 10_000_000 } // Fluent devnet block gas limit
        );
        await tx.wait();
        tokenAddress = await factory.bridgedTokens(l1Token);
        console.log("Universal Token deployed:", tokenAddress);

        const token = await ethers.getContractAt("IUniversalToken", tokenAddress);
        const totalSupply = await token.totalSupply();
        const deployerBalance = await token.balanceOf(address);
        console.log("Total supply:", ethers.formatUnits(totalSupply, decimals));
        console.log("Deployer balance:", ethers.formatUnits(deployerBalance, decimals));
    } catch (err) {
        console.warn("Token deployment failed (factory deployed successfully):", err.message);
        tokenAddress = null;
    }

    console.log("\n--- Deployment complete ---");
    console.log("UniversalTokenFactory:", factoryAddress);
    if (tokenAddress) console.log("Bridged Token (BDT):", tokenAddress);
}

main()
    .then(() => process.exit(0))
    .catch(err => {
        console.error(err);
        process.exit(1);
    });
