/**
 * Deploys ERC20TokenFactory as an upgradeable contract using @openzeppelin/hardhat-upgrades.
 *
 * @param {object} ethers - ethers from hardhat-ethers
 * @param {string} initialOwner - Owner of the factory (e.g. gateway or deployer)
 * @param {string} implementation - Initial token implementation for the beacon (e.g. ERC20PeggedToken)
 * @returns {Promise<{tokenFactory: Contract}>}
 */
async function deployERC20TokenFactoryProxy(ethers, initialOwner, implementation) {
    const hre = require("hardhat");
    const ERC20TokenFactory = await ethers.getContractFactory("ERC20TokenFactory");
    const tokenFactory = await hre.upgrades.deployProxy(
        ERC20TokenFactory,
        [initialOwner, implementation],
        {
            kind: "transparent",
            initializer: "initialize",
        }
    );
    await tokenFactory.waitForDeployment();
    return { tokenFactory };
}

module.exports = { deployERC20TokenFactoryProxy };
