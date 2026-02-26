const { ethers } = require("hardhat");

/**
 * Deploys UniversalTokenFactory for tests, linked against a mock UniversalTokenSDK.
 * Production deployments should use the real UniversalTokenSDK; tests only care about
 * deterministic addresses and successful deployment paths.
 *
 * @param {string} [initialOwner] - Owner of the factory (defaults to first signer)
 * @returns {Promise<{factory: Contract, library: Contract}>} library is the mock SDK
 */
async function deployUniversalTokenFactoryWithLinking(initialOwner) {
    const [deployer] = await ethers.getSigners();
    const owner = initialOwner ?? deployer.address;

    // Deploy the mock SDK library first
    const UniversalTokenSDKMock = await ethers.getContractFactory("UniversalTokenSDKMock");
    const library = await UniversalTokenSDKMock.connect(deployer).deploy();
    await library.waitForDeployment();
    const libraryAddress = await library.getAddress();

    // Deploy factory implementation with the mock SDK linked
    const Factory = await ethers.getContractFactory("UniversalTokenFactory", {
        libraries: {
            UniversalTokenSDK: libraryAddress,
        },
    });
    // For tests we can deploy the factory directly (non-upgradeable) since ownership is not exercised.
    const factory = await Factory.connect(deployer).deploy();
    await factory.waitForDeployment();

    return { factory, library };
}

module.exports = {
    deployUniversalTokenFactoryWithLinking,
};
