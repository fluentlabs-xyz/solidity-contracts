/**
 * Deploys FluentBridge as an upgradeable contract using @openzeppelin/hardhat-upgrades.
 * Uses transparent proxy; no custom proxy contract or manual deployment needed.
 *
 * @param {object} ethers - ethers from hardhat-ethers
 * @param {string} initialOwner - Owner of the bridge (and of the ProxyAdmin)
 * @param {string} bridgeAuthority - Address permitted to send authorized messages
 * @param {string} rollup - Rollup contract address (use zero address on L2)
 * @param {number|bigint} receiveMessageDeadline - Blocks after which message is eligible for rollback
 * @param {string} otherBridge - Address of the bridge on the other chain
 * @param {string} l1BlockOracle - L1 block oracle address
 * @returns {Promise<{bridge: Contract}>}
 */
async function deployFluentBridgeProxy(
    ethers,
    initialOwner,
    bridgeAuthority,
    rollup,
    receiveMessageDeadline,
    otherBridge,
    l1BlockOracle
) {
    const hre = require("hardhat");
    const FluentBridge = await ethers.getContractFactory("FluentBridge");
    const bridge = await hre.upgrades.deployProxy(
        FluentBridge,
        [initialOwner, bridgeAuthority, rollup, receiveMessageDeadline, otherBridge, l1BlockOracle],
        {
            kind: "transparent",
            initializer: "initialize",
        }
    );
    await bridge.waitForDeployment();
    return { bridge };
}

module.exports = { deployFluentBridgeProxy };
