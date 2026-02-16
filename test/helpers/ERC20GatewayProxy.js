/**
 * Deploys ERC20Gateway as an upgradeable contract using @openzeppelin/hardhat-upgrades.
 *
 * @param {object} ethers - ethers from hardhat-ethers
 * @param {string} initialOwner - Owner of the gateway
 * @param {string} bridgeContract - FluentBridge proxy address
 * @param {string} tokenFactory - ERC20TokenFactory proxy address
 * @param {object} opts - Optional { value } for payable initialize
 * @returns {Promise<{gateway: Contract}>}
 */
async function deployERC20GatewayProxy(ethers, initialOwner, bridgeContract, tokenFactory, opts = {}) {
    const hre = require("hardhat");
    const ERC20Gateway = await ethers.getContractFactory("ERC20Gateway");
    const { value, ...upgradeOpts } = opts;
    const gateway = await hre.upgrades.deployProxy(
        ERC20Gateway,
        [initialOwner, bridgeContract, tokenFactory],
        {
            kind: "transparent",
            initializer: "initialize",
            ...(value != null && { value }),
            ...upgradeOpts,
        }
    );
    await gateway.waitForDeployment();
    return { gateway };
}

module.exports = { deployERC20GatewayProxy };
