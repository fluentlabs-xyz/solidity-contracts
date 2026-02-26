/**
 * Deploy full ERC20 bridge stack on current network and run one test transfer of MockERC20Token
 * via ERC20Gateway (deposit on "L1", receive pegged token on "L2"). Simulates the relayer in-process.
 *
 * Usage (Hardhat local):
 *   npx hardhat run scripts/DeployAndTestERC20Transfer.js
 *
 * Usage (Sepolia + Fluent devnet): run on one network first to deploy "L1" side, then on the other
 *   for "L2" side, then run relayer separately (this script is for single-network / test).
 */
const hre = require("hardhat");
const { ethers } = require("hardhat");
const { deployFluentBridgeProxy } = require("../test/helpers/FluentBridgeProxy");
const { deployERC20TokenFactoryProxy } = require("../test/helpers/ERC20TokenFactoryProxy");
const { deployERC20GatewayProxy } = require("../test/helpers/ERC20GatewayProxy");
const { AbiCoder } = require("ethers");

const ZERO = "0x0000000000000000000000000000000000000000";

async function main() {
  const [deployer, recipient] = await ethers.getSigners();
  const bridgeAuthority = process.env.RELAYER_ADDRESS || deployer.address;

  console.log("Deployer:", deployer.address, "Recipient:", recipient.address, "Bridge authority:", bridgeAuthority);

  // --- 1. Oracles (bridges need l1BlockOracle) ---
  const L1BlockOracle = await ethers.getContractFactory("L1BlockOracle");
  const oracle = await L1BlockOracle.connect(deployer).deploy();
  await oracle.waitForDeployment();
  const oracleAddress = await oracle.getAddress();
  console.log("L1BlockOracle:", oracleAddress);

  // --- 2. Bridges (L1 and L2 on same network for test) ---
  const { bridge: bridgeL1 } = await deployFluentBridgeProxy(
    ethers,
    deployer.address,
    bridgeAuthority,
    ZERO,
    0,
    ZERO,
    oracleAddress
  );
  await bridgeL1.waitForDeployment();
  const bridgeL1Address = await bridgeL1.getAddress();

  const { bridge: bridgeL2 } = await deployFluentBridgeProxy(
    ethers,
    deployer.address,
    bridgeAuthority,
    ZERO,
    0,
    ZERO,
    oracleAddress
  );
  await bridgeL2.waitForDeployment();
  const bridgeL2Address = await bridgeL2.getAddress();

  await (await bridgeL1.setOtherBridge(bridgeL2Address)).wait();
  await (await bridgeL2.setOtherBridge(bridgeL1Address)).wait();
  console.log("Bridge L1:", bridgeL1Address, "Bridge L2:", bridgeL2Address);

  // --- 3. ERC20 pegged token implementation + factories ---
  const PeggedToken = await ethers.getContractFactory("ERC20PeggedToken");
  const peggedImpl = await PeggedToken.deploy();
  await peggedImpl.waitForDeployment();
  const peggedImplAddress = await peggedImpl.getAddress();
  console.log("ERC20PeggedToken impl:", peggedImplAddress);

  const { tokenFactory: factoryL1 } = await deployERC20TokenFactoryProxy(
    ethers,
    deployer.address,
    peggedImplAddress
  );
  await factoryL1.waitForDeployment();
  const factoryL1Address = await factoryL1.getAddress();

  const { tokenFactory: factoryL2 } = await deployERC20TokenFactoryProxy(
    ethers,
    deployer.address,
    peggedImplAddress
  );
  await factoryL2.waitForDeployment();
  const factoryL2Address = await factoryL2.getAddress();
  console.log("TokenFactory L1:", factoryL1Address, "L2:", factoryL2Address);

  // --- 4. Gateways ---
  const { gateway: gatewayL1 } = await deployERC20GatewayProxy(
    ethers,
    deployer.address,
    bridgeL1Address,
    factoryL1Address
  );
  await gatewayL1.waitForDeployment();
  const gatewayL1Address = await gatewayL1.getAddress();

  const { gateway: gatewayL2 } = await deployERC20GatewayProxy(
    ethers,
    deployer.address,
    bridgeL2Address,
    factoryL2Address
  );
  await gatewayL2.waitForDeployment();
  const gatewayL2Address = await gatewayL2.getAddress();
  console.log("Gateway L1:", gatewayL1Address, "Gateway L2:", gatewayL2Address);

  // --- 5. Wire factory ownership to gateways ---
  await (await factoryL1.transferOwnership(gatewayL1Address)).wait();
  await (await gatewayL1.acceptTokenFactory()).wait();
  await (await factoryL2.transferOwnership(gatewayL2Address)).wait();
  await (await gatewayL2.acceptTokenFactory()).wait();

  // --- 6. Set other side on both gateways ---
  await (
    await gatewayL1.setOtherSide(gatewayL2Address, peggedImplAddress, factoryL2Address)
  ).wait();
  await (
    await gatewayL2.setOtherSide(gatewayL1Address, peggedImplAddress, factoryL1Address)
  ).wait();

  // --- 7. Deploy MockERC20Token (deposit token on "L1") ---
  const MockERC20 = await ethers.getContractFactory("MockERC20Token");
  const initialSupply = ethers.parseEther("1000000");
  const mockToken = await MockERC20.deploy("Mock Deposit Token", "MDT", initialSupply, deployer.address);
  await mockToken.waitForDeployment();
  const mockTokenAddress = await mockToken.getAddress();
  console.log("MockERC20Token:", mockTokenAddress);

  // Optional: fund gateway for msg.value on sendMessage
  await (
    await deployer.sendTransaction({
      to: gatewayL1Address,
      value: ethers.parseEther("0.1"),
    })
  ).wait();

  // --- 8. Test transfer: approve and sendTokens (L1 -> L2) ---
  const transferAmount = 1000n;
  await (await mockToken.approve(gatewayL1Address, transferAmount)).wait();

  const sendTx = await gatewayL1.sendTokens(mockTokenAddress, recipient.address, transferAmount);
  const sendReceipt = await sendTx.wait();
  console.log("sendTokens tx:", sendReceipt.hash);

  // --- 9. Simulate relayer: read SentMessage from Bridge L1, call receiveMessage on Bridge L2 ---
  const bridgeL1WithSigner = bridgeL1.connect(deployer);
  const events = await bridgeL1WithSigner.queryFilter(
    bridgeL1WithSigner.filters.SentMessage(),
    sendReceipt.blockNumber,
    sendReceipt.blockNumber
  );
  if (events.length === 0) {
    throw new Error("No SentMessage event found");
  }
  const ev = events[0];
  const args = ev.args;
  const from = args.sender;
  const to = args.to;
  const value = args.value;
  const chainId = args.chainId;
  const blockNumber = args.blockNumber;
  const nonce = args.nonce;
  const data = args.data;

  const expectedNonce = await bridgeL2.receivedNonce();
  const receiveTx = await bridgeL2.receiveMessage(from, to, value, chainId, blockNumber, expectedNonce, data);
  const receiveReceipt = await receiveTx.wait();
  console.log("receiveMessage (relay) tx:", receiveReceipt.hash);

  // Check relay succeeded (bridge emits ReceivedMessage(successfulCall))
  const receivedEvent = receiveReceipt.logs.find(
    (log) => {
      try {
        const parsed = bridgeL2.interface.parseLog({ topics: log.topics, data: log.data });
        return parsed && parsed.name === "ReceivedMessage";
      } catch {
        return false;
      }
    }
  );
  if (receivedEvent) {
    const parsed = bridgeL2.interface.parseLog({ topics: receivedEvent.topics, data: receivedEvent.data });
    if (!parsed.args.successfulCall) throw new Error("Relay call to gateway failed");
  }

  // --- 10. Verify: get pegged token from TokenDeployed event (factory L2) ---
  const factoryL2Interface = factoryL2.interface;
  let peggedTokenAddress = null;
  for (const log of receiveReceipt.logs) {
    if (log.address.toLowerCase() !== factoryL2Address.toLowerCase()) continue;
    try {
      const parsed = factoryL2Interface.parseLog({ topics: log.topics, data: log.data });
      if (parsed && parsed.name === "TokenDeployed") {
        peggedTokenAddress = parsed.args.peggedToken ?? parsed.args[1];
        break;
      }
    } catch (_) {}
  }
  if (!peggedTokenAddress) {
    peggedTokenAddress = await factoryL2.computePeggedTokenAddress(gatewayL2Address, mockTokenAddress);
  }

  const peggedToken = await ethers.getContractAt("ERC20PeggedToken", peggedTokenAddress);
  const balance = await peggedToken.balanceOf(recipient.address);
  const name = await peggedToken.name();
  const symbol = await peggedToken.symbol();

  console.log("\n--- Result ---");
  console.log("Pegged token (L2):", peggedTokenAddress);
  console.log("Name:", name, "Symbol:", symbol);
  console.log("Recipient balance:", balance.toString());
  if (balance !== transferAmount) {
    throw new Error("Recipient balance mismatch: expected " + transferAmount + ", got " + balance);
  }
  console.log("Test transfer OK.");
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
