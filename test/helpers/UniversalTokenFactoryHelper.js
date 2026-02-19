const { ethers } = require("hardhat");

/**
 * Deploys UniversalTokenSDK library and UniversalTokenFactory with proper linking.
 * Required because UniversalTokenFactory uses UniversalTokenSDK library (public functions).
 *
 * @returns {Promise<{factory: Contract, library: Contract}>}
 */
async function deployUniversalTokenFactoryWithLinking() {
  const [deployer] = await ethers.getSigners();

  // Deploy the library first
  const UniversalTokenSDK = await ethers.getContractFactory("UniversalTokenSDK");
  const library = await UniversalTokenSDK.connect(deployer).deploy();
  await library.waitForDeployment();
  const libraryAddress = await library.getAddress();

  // Deploy factory with library linked
  const Factory = await ethers.getContractFactory("UniversalTokenFactory", {
    libraries: {
      UniversalTokenSDK: libraryAddress,
    },
  });
  const factory = await Factory.connect(deployer).deploy();
  await factory.waitForDeployment();

  return { factory, library };
}

module.exports = {
  deployUniversalTokenFactoryWithLinking,
};
