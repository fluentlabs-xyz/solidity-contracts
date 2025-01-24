import { expect } from "chai";
import { readFileSync } from "fs"
import { dirname, join } from "path"


describe("ComputationVerifier", function () {
    let computationVerifier;
    let owner


    beforeEach(async function () {
        const ComputationVerifier = await ethers.getContractFactory("ComputationVerifier");
        computationVerifier = await ComputationVerifier.deploy();
        await computationVerifier.waitForDeployment();
        [owner] = await ethers.getSigners();
    });

    it("should create a new challenge", async function () {
        const wasmHash = ethers.id("wasm_test_hash");
        const inputHash = ethers.id("input_test_hash");
        const outputHash = ethers.id("output_test_hash");

        await expect(computationVerifier.createChallenge(wasmHash, inputHash, outputHash))
            .to.emit(computationVerifier, "ChallengeCreated")
            .withArgs(0, owner.address, wasmHash, inputHash, outputHash);

        const challenge = await computationVerifier.challenges(0);

        expect(challenge.wasmHash).to.equal(wasmHash);
        expect(challenge.inputHash).to.equal(inputHash);
        expect(challenge.outputHash).to.equal(outputHash);
        expect(challenge.exists).to.be.true;
        expect(challenge.verified).to.be.false;
    });

    it("should successfully verify computation", async function () {
        const wasmHash = ethers.id("wasm_test_hash");
        const inputHash = ethers.id("input_test_hash");
        const outputHash = ethers.id("output_test_hash");


    });


});
