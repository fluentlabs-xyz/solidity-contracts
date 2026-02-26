const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployUniversalTokenFactoryWithLinking } = require("../helpers/UniversalTokenFactoryHelper");

// Encode keyData = abi.encode(l1Token, chainId)
function encodeKeyData(l1Token, chainId) {
    return ethers.AbiCoder.defaultAbiCoder().encode(["address", "uint256"], [l1Token, chainId]);
}
// Encode deployArgs = abi.encode(name, symbol, decimals, initialSupply, minter, pauser)
function encodeDeployArgs(name, symbol, decimals, initialSupply, minter, pauser) {
    return ethers.AbiCoder.defaultAbiCoder().encode(
        ["string", "string", "uint8", "uint256", "address", "address"],
        [name, symbol, decimals, initialSupply, minter, pauser]
    );
}

// Impersonation: Hardhat uses hardhat_*, Anvil uses anvil_*
async function impersonateAccount(provider, address) {
    const method = process.env.HARDHAT_NETWORK === "anvil-fluent-fork" ? "anvil_impersonateAccount" : "hardhat_impersonateAccount";
    await provider.send(method, [address]);
}

async function stopImpersonatingAccount(provider, address) {
    const method = process.env.HARDHAT_NETWORK === "anvil-fluent-fork" ? "anvil_stopImpersonatingAccount" : "hardhat_stopImpersonatingAccount";
    await provider.send(method, [address]);
}

// Run deployBridgedTokenCreate2 tests only on live fluent-dev (has precompile at 0x520008).
// anvil-fluent-fork has funds via impersonation but no precompile.
const hasFluentPrecompile = process.env.HARDHAT_NETWORK === "fluent-dev";

// Gas limit for deployBridgedTokenCreate2 (matches Fluent/Rust side)
const DEPLOY_BRIDGED_TOKEN_GAS_LIMIT = 50_000_000n;

// Funded account on fluent-dev - we impersonate it on anvil fork to move funds to local signer
const FLUENT_DEV_FUNDED_ACCOUNT = "0xD914e88f30D31188d0f71843310BC3E0F35Ea41b";

describe("UniversalTokenFactory", function () {
    this.timeout(60000); // 60s for RPC calls

    let factory;
    let deployer;

    before(async function () {
        [deployer] = await ethers.getSigners();

        // On anvil-fluent-fork: impersonate funded account and move ETH to local deployer
        if (process.env.HARDHAT_NETWORK === "anvil-fluent-fork") {
            const provider = ethers.provider;
            await impersonateAccount(provider, FLUENT_DEV_FUNDED_ACCOUNT);
            const fundedSigner = await ethers.getSigner(FLUENT_DEV_FUNDED_ACCOUNT);
            const balance = await provider.getBalance(FLUENT_DEV_FUNDED_ACCOUNT);
            const amountToSend = balance / 2n; // Send half to keep some for other uses
            if (amountToSend > 0n) {
                await fundedSigner.sendTransaction({
                    to: deployer.address,
                    value: amountToSend,
                });
            }
            await stopImpersonatingAccount(provider, FLUENT_DEV_FUNDED_ACCOUNT);
        }

        const { factory: f } = await deployUniversalTokenFactoryWithLinking();
        factory = f;
    });

    describe("computeTokenAddress (keyData + deployArgs)", function () {
        it("should compute deterministic CREATE2 addresses for given inputs", async function () {
            const l1Token = "0x1111111111111111111111111111111111111111";
            const chainId = 20993;
            const name = "Test Token";
            const symbol = "TEST";
            const decimals = 18;
            const initialSupply = 0n;
            const minter = deployer.address;
            const pauser = ethers.ZeroAddress;

            const keyData = encodeKeyData(l1Token, chainId);
            const deployArgs = encodeDeployArgs(name, symbol, decimals, initialSupply, minter, pauser);
            const address1 = await factory.computeTokenAddress(keyData, deployArgs);
            const address2 = await factory.computeTokenAddress(keyData, deployArgs);

            expect(address1).to.equal(address2);
            expect(address1).to.not.equal(ethers.ZeroAddress);
        });

        it("should produce different addresses for different L1 tokens", async function () {
            const chainId = 20993;
            const deployArgs = encodeDeployArgs("Test Token", "TEST", 18, 0n, deployer.address, ethers.ZeroAddress);

            const addr1 = await factory.computeTokenAddress(encodeKeyData("0x1111111111111111111111111111111111111111", chainId), deployArgs);
            const addr2 = await factory.computeTokenAddress(encodeKeyData("0x2222222222222222222222222222222222222222", chainId), deployArgs);

            expect(addr1).to.not.equal(addr2);
        });

        it("should produce different addresses for different chain IDs", async function () {
            const l1Token = "0x1111111111111111111111111111111111111111";
            const deployArgs = encodeDeployArgs("Test Token", "TEST", 18, 0n, deployer.address, ethers.ZeroAddress);

            const addr1 = await factory.computeTokenAddress(encodeKeyData(l1Token, 20993), deployArgs);
            const addr2 = await factory.computeTokenAddress(encodeKeyData(l1Token, 1), deployArgs);

            expect(addr1).to.not.equal(addr2);
        });
    });

    describe("computeBridgeTokenSalt (via computeTokenAddress)", function () {
        it("should compute deterministic salt for given token and chain ID", async function () {
            const l1Token = "0x1111111111111111111111111111111111111111";
            const chainId = 1337;
            const deployArgs = encodeDeployArgs("Test", "TST", 18, 0n, deployer.address, ethers.ZeroAddress);

            const expectedSalt = ethers.keccak256(ethers.solidityPacked(["string", "address", "uint256"], ["BRIDGE_TOKEN", l1Token, chainId]));
            expect(expectedSalt).to.not.equal(ethers.ZeroHash);

            const keyData = encodeKeyData(l1Token, chainId);
            const address1 = await factory.computeTokenAddress(keyData, deployArgs);
            const address2 = await factory.computeTokenAddress(keyData, deployArgs);
            expect(address1).to.equal(address2);
        });
    });

    describe("deployToken (Fluent Node integration)", function () {
        it("should deploy a Universal Token via CREATE2 on Fluent Node", async function () {
            if (!hasFluentPrecompile) {
                this.skip();
            }

            const l1Token = ethers.Wallet.createRandom().address;
            const chainId = 20993;
            const name = "Bridged Test Token";
            const symbol = "BTT";
            const decimals = 18;
            const initialSupply = 1000000n * 10n ** 18n;
            const minter = deployer.address;
            const pauser = ethers.ZeroAddress;

            const keyData = encodeKeyData(l1Token, chainId);
            const deployArgs = encodeDeployArgs(name, symbol, decimals, initialSupply, minter, pauser);
            const predictedAddress = await factory.computeTokenAddress(keyData, deployArgs);

            const tx = await factory.deployToken(keyData, deployArgs, { gasLimit: DEPLOY_BRIDGED_TOKEN_GAS_LIMIT });
            const receipt = await tx.wait();

            expect(receipt.status).to.equal(1);

            const deployedToken = await factory.bridgedTokens(l1Token);
            expect(deployedToken).to.not.equal(ethers.ZeroAddress);
            expect(deployedToken).to.equal(predictedAddress);

            const tokenInfo = await factory.tokenInfo(deployedToken);
            expect(tokenInfo.l1Token).to.equal(l1Token);
            expect(tokenInfo.chainId).to.equal(BigInt(chainId));
            expect(tokenInfo.deployed).to.be.true;

            const IUniversalToken = await ethers.getContractAt("IUniversalToken", deployedToken);
            expect(await IUniversalToken.name()).to.equal(name);
            expect(await IUniversalToken.symbol()).to.equal(symbol);
            expect(await IUniversalToken.decimals()).to.equal(BigInt(decimals));
            expect(await IUniversalToken.totalSupply()).to.equal(initialSupply);
            expect(await IUniversalToken.balanceOf(deployer.address)).to.equal(initialSupply);
        });

        it("should revert when deploying same L1 token twice", async function () {
            if (!hasFluentPrecompile) {
                this.skip();
            }

            const l1Token = ethers.Wallet.createRandom().address;
            const chainId = 20993;
            const deployArgs = encodeDeployArgs("Duplicate Token", "DUP", 18, 1000n, deployer.address, ethers.ZeroAddress);
            const keyData = encodeKeyData(l1Token, chainId);

            await factory.deployToken(keyData, deployArgs, { gasLimit: DEPLOY_BRIDGED_TOKEN_GAS_LIMIT });

            try {
                await factory.deployToken(keyData, deployArgs, { gasLimit: DEPLOY_BRIDGED_TOKEN_GAS_LIMIT });
                expect.fail("Expected revert");
            } catch (error) {
                expect(error.message).to.include("UniversalTokenFactory: token already deployed");
            }
        });

        it("should revert when L1 token is zero address", async function () {
            const deployArgs = encodeDeployArgs("Test", "TST", 18, 0n, deployer.address, ethers.ZeroAddress);
            const keyData = encodeKeyData(ethers.ZeroAddress, 20993);

            try {
                await factory.deployToken(keyData, deployArgs);
                expect.fail("Expected revert");
            } catch (error) {
                expect(error.message).to.include("UniversalTokenFactory: invalid L1 token");
            }
        });

        it("should revert when chain ID is zero", async function () {
            const deployArgs = encodeDeployArgs("Test", "TST", 18, 0n, deployer.address, ethers.ZeroAddress);
            const keyData = encodeKeyData(deployer.address, 0);

            try {
                await factory.deployToken(keyData, deployArgs);
                expect.fail("Expected revert");
            } catch (error) {
                expect(error.message).to.include("UniversalTokenFactory: invalid chain ID");
            }
        });
    });

    describe("TokenDeployed event", function () {
        it("should emit TokenDeployed on successful deployment", async function () {
            if (!hasFluentPrecompile) {
                this.skip();
            }

            const l1Token = ethers.Wallet.createRandom().address;
            const chainId = 20993;
            const name = "Event Test Token";
            const symbol = "EVT";
            const decimals = 18;
            const initialSupply = 500n;
            const minter = deployer.address;
            const pauser = ethers.ZeroAddress;

            const keyData = encodeKeyData(l1Token, chainId);
            const deployArgs = encodeDeployArgs(name, symbol, decimals, initialSupply, minter, pauser);
            const predictedAddr = await factory.computeTokenAddress(keyData, deployArgs);
            const tx = await factory.deployToken(keyData, deployArgs, { gasLimit: DEPLOY_BRIDGED_TOKEN_GAS_LIMIT });
            const receipt = await tx.wait();
            const factoryAddress = await factory.getAddress();
            const eventLog = receipt.logs.find(l => l.address.toLowerCase() === factoryAddress.toLowerCase());
            expect(eventLog).to.not.be.undefined;
            const parsed = factory.interface.parseLog({
                topics: eventLog.topics,
                data: eventLog.data,
            });
            expect(parsed.name).to.equal("TokenDeployed");
            expect(parsed.args.l1Token).to.equal(l1Token);
            expect(parsed.args.l2Token).to.equal(predictedAddr);
            expect(parsed.args.name).to.equal(name);
            expect(parsed.args.symbol).to.equal(symbol);
        });
    });
});
