/**
 * Deploy ERC20 gateway stack (pegged token impl, token factory, gateway) for no-rollup.
 * Run once per chain after the bridge is deployed and otherBridge is set.
 *
 * Usage:
 *   BRIDGE_ADDRESS=0x... npx hardhat run scripts/DeployERC20GatewayNoRollup.js --network sepoliaEth
 *   BRIDGE_ADDRESS=0x... npx hardhat run scripts/DeployERC20GatewayNoRollup.js --network fluentDev
 *
 * Env: BRIDGE_ADDRESS (required) - FluentBridge address on this chain.
 * Output: ERC20PeggedTokenImpl:, ERC20TokenFactory:, ERC20Gateway: (parse from log).
 */
const { ethers } = require("hardhat");
const { deployERC20TokenFactoryProxy } = require("../test/helpers/ERC20TokenFactoryProxy");
const { deployERC20GatewayProxy } = require("../test/helpers/ERC20GatewayProxy");

async function main() {
    const bridgeAddress = process.env.BRIDGE_ADDRESS;
    if (!bridgeAddress) {
        console.error("Set BRIDGE_ADDRESS (FluentBridge on this chain).");
        process.exit(1);
    }

    const [deployer] = await ethers.getSigners();
    const network = await ethers.provider.getNetwork();
    const chainId = Number(network.chainId);

    console.log("Network:", chainId, "Deployer:", deployer.address, "Bridge:", bridgeAddress);

    const PeggedToken = await ethers.getContractFactory("ERC20PeggedToken");
    const peggedImpl = await PeggedToken.deploy();
    await peggedImpl.waitForDeployment();
    const implAddress = await peggedImpl.getAddress();
    console.log("ERC20PeggedTokenImpl:", implAddress);

    const { tokenFactory } = await deployERC20TokenFactoryProxy(ethers, deployer.address, implAddress);
    await tokenFactory.waitForDeployment();
    const factoryAddress = await tokenFactory.getAddress();
    const factoryBeacon = await tokenFactory.beacon();
    console.log("ERC20TokenFactory:", factoryAddress);
    console.log("ERC20TokenFactoryBeacon:", factoryBeacon);

    const { gateway } = await deployERC20GatewayProxy(ethers, deployer.address, bridgeAddress, factoryAddress);
    await gateway.waitForDeployment();
    const gatewayAddress = await gateway.getAddress();
    console.log("ERC20Gateway:", gatewayAddress);

    await (await tokenFactory.transferOwnership(gatewayAddress)).wait();
    await (await gateway.acceptTokenFactory()).wait();
    console.log("Factory ownership transferred to gateway and accepted.");
}

main()
    .then(() => process.exit(0))
    .catch(err => {
        console.error(err);
        process.exit(1);
    });
