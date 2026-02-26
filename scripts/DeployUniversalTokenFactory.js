const { ethers } = require("hardhat");
const { deployUniversalTokenFactoryWithLinking } = require("../test/helpers/UniversalTokenFactoryHelper");

const FLUENT_DEV_CHAIN_ID = 20993;

function encodeKeyData(l1Token, chainId) {
    return ethers.AbiCoder.defaultAbiCoder().encode(["address", "uint256"], [l1Token, chainId]);
}
function encodeDeployArgs(name, symbol, decimals, initialSupply, minter, pauser) {
    return ethers.AbiCoder.defaultAbiCoder().encode(
        ["string", "string", "uint8", "uint256", "address", "address"],
        [name, symbol, decimals, initialSupply, minter, pauser]
    );
}

async function main() {
    const [deployer] = await ethers.getSigners();
    const address = await deployer.getAddress();

    console.log("Deploying to Fluent Dev (chainId:", FLUENT_DEV_CHAIN_ID, ")");
    console.log("Deployer:", address);

    const balance = await ethers.provider.getBalance(address);
    console.log("Balance:", ethers.formatEther(balance), "ETH");

    // 1. Deploy UniversalTokenFactory (proxy + implementation with SDK library)
    console.log("\n--- Deploying UniversalTokenFactory ---");
    const { factory, library } = await deployUniversalTokenFactoryWithLinking(address);
    const factoryAddress = await factory.getAddress();
    const libraryAddress = await library.getAddress();

    console.log("UniversalTokenSDK library:", libraryAddress);
    console.log("UniversalTokenFactory (proxy):", factoryAddress);

    // 2. Deploy a bridged token via deployToken(keyData, deployArgs)
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
        const keyData = encodeKeyData(l1Token, chainId);
        const deployArgs = encodeDeployArgs(name, symbol, decimals, initialSupply, minter, pauser);
        const tx = await factory.deployToken(keyData, deployArgs, { gasLimit: 10_000_000 });
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
