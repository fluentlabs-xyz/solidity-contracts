import { expect } from "chai";
import { readFileSync } from "fs"
import { dirname, join } from "path"


describe("Deployment", function () {
    it("wasm deployer should deploy greeting.wasm", async function () {
        console.log("deploying WasmDeployer.sol...");
        const WasmDeployer = await ethers.getContractFactory("WasmDeployer");
        const contract = await WasmDeployer.deploy();
        await contract.waitForDeployment();
        const wasmFilename = "./assets/greeting.wasm";
        const wasmBytecode = "0x" + readFileSync(join(dirname(import.meta.filename), wasmFilename)).toString("hex");
        const constructorParams = "0x"; // empty constructor
        const transaction = await contract.deploy(wasmBytecode, constructorParams, { gasLimit: 30000000 })
        const receipt = await transaction.wait();
        await expect(receipt).to.emit(contract, "Deployed")
            .withArgs((address) => address !== "0x0000000000000000000000000000000000000000");
    });
    it("wasm deployer should deploy constructor-params.wasm", async function () {
        if (network.name === 'hardhat') {
            console.warn('⚠️  WASM tests require a Fluent-compatible network');
            this.skip();
        }
        console.log("deploying WasmDeployer.sol...");
        const WasmDeployer = await ethers.getContractFactory("WasmDeployer");
        const contract = await WasmDeployer.deploy();
        await contract.waitForDeployment();
        const wasmFilename = "./assets/constructor-params.wasm";
        const wasmBytecode = "0x" + readFileSync(join(dirname(import.meta.filename), wasmFilename)).toString("hex");
        const constructorParams = "0x12345678ffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
        console.log("executing \"deploy(bytecode, params)\" of WasmDeployer.sol...");
        const transaction = await contract.deploy(wasmBytecode, constructorParams, { gasLimit: 30000000 })
        const receipt = await transaction.wait();
        await expect(receipt).to.emit(contract, "Deployed")
            .withArgs((address) => address !== "0x0000000000000000000000000000000000000000");
        const newContractAddress = receipt.logs[0].args[0];
        // const newContractAddress = "0x56639dB16Ac50A89228026e42a316B30179A5376";
        const signer = (await ethers.getSigners())[0];
        const output = await signer.call({'to': newContractAddress, 'data': "0x"});
        await expect(output).to.equal(constructorParams);
    });
});
