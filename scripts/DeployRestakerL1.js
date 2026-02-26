const { ethers } = require("hardhat");
const { BigNumber } = require("ethers");
const {vars} = require("hardhat/config");

const RESTAKER_PROVIDER = "RESTAKER_PROVIDER";

async function main() {
  let provider_url = "https://ethereum-holesky-rpc.publicnode.com";
  // let provider_url = "http://127.0.0.1:8545/";

  const privateKey = vars.get("HOLESKY_PRIVATE_KEY");
  let provider = new ethers.JsonRpcProvider(provider_url);

  let signer = new ethers.Wallet(privateKey, provider);
  // signer = provider.getSigner()

  await deployRestakerL1(
    provider,
    signer,
    "0x5D53ec5B0eB1dCBaAe425A0c5ae79354467cd6fA",
  );
}

async function deployRestakerL1(provider, signer, bridgeAddress) {
  let awaiting = [];

  let nonce = await provider.getTransactionCount(signer.address, "pending");

  console.log("Pending nonce: ", nonce);
  const ProtocolConfig = await ethers.getContractFactory("ProtocolConfig");
  // let protocolConfig = await ProtocolConfig.connect(l1Signer).attach("0xd3f649a83c4d078c533a06188f6f17661b7639d9");
  let protocolConfig = await ProtocolConfig.connect(signer).deploy(
    signer.getAddress(),
    signer.getAddress(),
    signer.getAddress(),
    {
      nonce: nonce++,
    },
  );
  awaiting.push(protocolConfig.waitForDeployment());

  console.log("Protocol config: ", protocolConfig.target);

  console.log("Pending nonce: ", nonce);
  const RatioFeed = await ethers.getContractFactory("RatioFeed");
  // let ratioFeed = await RatioFeed.connect(l1Signer).attach("0xd15ba44ce9e19509073bd35476a11f8902ae1f8b")
  let ratioFeed = await RatioFeed.connect(signer).deploy(
    protocolConfig.target,
    "40000",
    {
      nonce: nonce++,
    },
  );
  console.log("Pending nonce: ", nonce);
  awaiting.push(ratioFeed.waitForDeployment());
  console.log("Ratio feed: ", ratioFeed.target);

  let setRatioFeed = await protocolConfig.setRatioFeed(ratioFeed.target, {
    nonce: nonce++,
  });
  console.log("Set ratio feet");
  awaiting.push(setRatioFeed.wait());

  console.log("Set ratio feet");

  const LiquidityToken = await ethers.getContractFactory("LiquidityToken");
  // let liquidityToken = await LiquidityToken.connect(l1Signer).attach("0x8817e50f7af3415cf1402cbc6bf46206dd80b52d");
  let liquidityToken = await LiquidityToken.connect(signer).deploy(
    protocolConfig.target,
    "Liquidity Token",
    "lETH",
    {
      nonce: nonce++,
    },
  );
  awaiting.push(liquidityToken.waitForDeployment());

  console.log("LiquidutyToken: ", liquidityToken.target);

  let updateRatio = await ratioFeed.updateRatio(liquidityToken.target, 1000, {
    nonce: nonce++,
  });
  awaiting.push(updateRatio.wait());

  console.log("updateRation: ", updateRatio.target);

  let setToken = await protocolConfig.setLiquidityToken(
    liquidityToken.target,
    {
      nonce: nonce++,
    },
  );
  awaiting.push(setToken.wait());

  console.log("setToken: ", setToken.target);

  const RestakingPool = await ethers.getContractFactory("RestakingPool");
  // let restakingPool = await RestakingPool.connect(l1Signer).attach("0xfae844C4deb40A72015e7A198C7B87C8B3d06b2A");
  let restakingPool = await RestakingPool.connect(signer).deploy(
    protocolConfig.target,
    "200000",
    "200000000000000000000",
    {
      nonce: nonce++,
    },
  );
  awaiting.push(restakingPool.waitForDeployment());
  console.log("Restaking pool: ", restakingPool.target);

  let setPool = await protocolConfig.setRestakingPool(restakingPool.target, {
    nonce: nonce++,
  });
  awaiting.push(setPool.wait());
  console.log("settedPool");

  const FeeCollector = await ethers.getContractFactory("FeeCollector");
  let feeCollector = await FeeCollector.connect(signer).deploy(
    protocolConfig.target,
    "1500",
    {
      nonce: nonce++,
    },
  );
  awaiting.push(feeCollector.waitForDeployment());
  console.log("FeeCollector: ", feeCollector.target);

  const PeggedToken = await ethers.getContractFactory("ERC20PeggedToken");
  let peggedToken = await PeggedToken.connect(signer).deploy({
    nonce: nonce++,
  });
  awaiting.push(peggedToken.waitForDeployment());
  console.log("ERC20PeggedToken: ", peggedToken.target);

  const hre = require("hardhat");
  const TokenFactoryContract =
    await ethers.getContractFactory("ERC20TokenFactory");
  let tokenFactory = await hre.upgrades.deployProxy(
    TokenFactoryContract,
    [await signer.getAddress(), peggedToken.target],
    { kind: "transparent", initializer: "initialize" },
  );
  awaiting.push(tokenFactory.waitForDeployment());
  console.log("ERC20TokenFactory: ", tokenFactory.target);

  const RestakerGateway = await ethers.getContractFactory("RestakerGateway");
  let restakerGateway = await RestakerGateway.connect(signer).deploy(
    bridgeAddress,
    restakingPool.target,
    tokenFactory.target,
    {
      nonce: nonce++,
    },
  );
  awaiting.push(restakerGateway.waitForDeployment());
  console.log("REstaking gateway, ", restakerGateway.target);

  // const EigenPodMock    = await ethers.getContractFactory("EigenPodMock");
  // let eigenPodMock = await EigenPodMock.connect(l1Signer).deploy(
  //     "0x0000000000000000000000000000000000000000",
  //     "0x0000000000000000000000000000000000000000",
  //     "0x0000000000000000000000000000000000000000",
  //     0
  // )
  // awaiting.push(eigenPodMock.waitForDeployment());
  // console.log("EigenPodMock: ", eigenPodMock.target);

  const UpgradeableBeacon =
    await ethers.getContractFactory("UpgradeableBeacon");
  // let upgradeableBeacon = await UpgradeableBeacon.connect(l1Signer).deploy(
  //     eigenPodMock.target,
  //     await l1Signer.getAddress(), {
  //       gasLimit: 300000,
  //     }
  // );
  // awaiting.push(upgradeableBeacon.waitForDeployment());
  // console.log("UpgradeableBeacon: ", upgradeableBeacon.target);

  // const EigenPodManagerMock    = await ethers.getContractFactory("EigenPodManagerMock");
  // let eigenPodManagerMock = await EigenPodManagerMock.connect(l1Signer).deploy(
  //     "0x0000000000000000000000000000000000000000",
  //     upgradeableBeacon.target,
  //     "0x0000000000000000000000000000000000000000",
  //     "0x0000000000000000000000000000000000000000",
  // )
  // awaiting.push(eigenPodManagerMock.waitForDeployment());
  // console.log("EigenPodManagerMock: ", eigenPodManagerMock.target);

  // const DelegationManagerMock    = await ethers.getContractFactory("DelegationManagerMock");
  // let delegationManagerMock = await DelegationManagerMock.connect(l1Signer).deploy()
  // awaiting.push(delegationManagerMock.waitForDeployment());
  // console.log("DelegationManagerMock: ", delegationManagerMock.target);

  const RestakerFacets = await ethers.getContractFactory("RestakerFacets");
  let restakerFacets = await RestakerFacets.connect(signer).deploy(
    signer.getAddress(),
    // eigenPodManagerMock.target,
    "0x30770d7E3e71112d7A6b7259542D1f680a70e315",
    // delegationManagerMock.target,
    "0xA44151489861Fe9e3055d95adC98FbD462B948e7",
    {
      nonce: nonce++,
    },
  );
  awaiting.push(restakerFacets.waitForDeployment());
  console.log("RestakerFacets: ", restakerFacets.target);

  const Restaker = await ethers.getContractFactory("Restaker");
  let restaker = await Restaker.connect(signer).deploy({
    nonce: nonce++,
  });
  awaiting.push(restaker.waitForDeployment());

  console.log("Restaker: ", restaker.target);

  let upgradeableBeacon = await UpgradeableBeacon.connect(signer).deploy(
    restaker.target,
    await signer.getAddress(),
    {
      gasLimit: 300000,
      nonce: nonce++,
    },
  );
  awaiting.push(upgradeableBeacon.waitForDeployment());

  console.log("UpgradeableBeacon: ", upgradeableBeacon.target);

  const RestakerDeployer = await ethers.getContractFactory("RestakerDeployer");
  let restakerDeployer = await RestakerDeployer.connect(signer).deploy(
    upgradeableBeacon.target,
    restakerFacets.target,
    {
      nonce: nonce++,
    },
  );
  awaiting.push(restakerDeployer.waitForDeployment());

  console.log("RestakerDeployer: ", restakerDeployer.target);

  let setDeployer = await protocolConfig.setRestakerDeployer(
    restakerDeployer.target,
    {
      nonce: nonce++,
    },
  );
  awaiting.push(setDeployer.wait());
  console.log("setDeployer");

  const authTx = await tokenFactory.transferOwnership(restakerGateway.target, {
    nonce: nonce++,
  });
  awaiting.push(authTx.wait());

  console.log("authTx");

  let addRestaker = await restakingPool.addRestaker(RESTAKER_PROVIDER, {
    gasLimit: 1000000,
    nonce: nonce++,
  });
  awaiting.push(addRestaker.wait());
  console.log("addRestaker");

  await Promise.all(awaiting);

  console.log("Restaking Gateway contracts deployed");
  return {
    restakerGateway: restakerGateway.target,
    restakingPool: restakingPool.target,
    liquidityToken: liquidityToken.target,
    tokenFactory: tokenFactory.target,
    peggedToken: peggedToken.target,
  };
}

module.exports = deployRestakerL1;

if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}
