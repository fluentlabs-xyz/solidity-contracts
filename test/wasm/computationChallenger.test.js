let expect = require("chai").expect;
const utils = require("./utils");

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

        const transaction = await computationVerifier.createChallenge(wasmHash, inputHash, outputHash)
        const receipt = await transaction.wait();

        expect(receipt)
            .to.emit(computationVerifier, "ChallengeCreated")
            .withArgs(0, owner.address, wasmHash, inputHash, outputHash);

        const challenge = await computationVerifier.challenges(0);

        expect(challenge.wasmHash).to.equal(wasmHash);
        expect(challenge.inputHash).to.equal(inputHash);
        expect(challenge.outputHash).to.equal(outputHash);
        expect(challenge.verified).to.be.false;
    });

    it("should fail when verifying non-existing challenge", async function () {
        await expect(computationVerifier.verifyComputation(999, "0x00", "0x00")).to.be.revertedWithCustomError(computationVerifier, "ChallengeDoesNotExist");
    });

    it("should verify computation of echo.wasm", async function () {
        if (network.name === 'hardhat') {
            console.warn('⚠️  WASM tests require a Fluent-compatible network');
            this.skip();
        }
        const wasmBytecode = utils.readBytecode("./assets/echo.wasm");
        const wasmHash = ethers.keccak256(wasmBytecode);
        const input = "0x12345678ffff"
        const inputHash = ethers.keccak256(input);
        const outputHash = ethers.keccak256(input);


        let transaction = await computationVerifier.createChallenge(wasmHash, inputHash, outputHash)
        let receipt = await transaction.wait();
        expect(receipt.status == 1);
        const challengeID = receipt.logs[0].args[0];

        let error = false;
        try {
            transaction = await computationVerifier.verifyComputation(challengeID, wasmBytecode, "0xbad0000000");
            receipt = await transaction.wait();
        } catch {
            error = true;
        }
        expect(error, "verification with invalid input should fail");

        transaction = await computationVerifier.verifyComputation(challengeID, wasmBytecode, input);
        receipt = await transaction.wait();

        const challenge = await computationVerifier.challenges(0);
        expect(challenge.wasmHash).to.equal(wasmHash);
        expect(challenge.inputHash).to.equal(inputHash);
        expect(challenge.outputHash).to.equal(outputHash);
        expect(challenge.verified).to.be.true;
    });


});
