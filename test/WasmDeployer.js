import { expect } from "chai";
import hre from "hardhat";

describe("Deployment", function () {
    it("wasm deployer should emit event", async function () {
        const WasmDeployer = await ethers.getContractFactory("WasmDeployer");
        const deployer = await WasmDeployer.deploy();
        const wasmBytecode = "0x600a600c600039600a6000f3602a6017f3"; // Example bytecode (not functional)
        const constructorParams = "0xffff"; // Example constructor parameters
        const result = deployer.deploy(wasmBytecode, constructorParams)
        await expect(result).to.emit(deployer, "WasmContractDeployed")
            .withArgs((address) => address !== "0x0000000000000000000000000000000000000000");
    });
});
