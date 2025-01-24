// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {WasmDeployerLib} from "./WasmDeployerLib.sol";

contract ComputationVerifier {
    event ChallengeCreated(uint256 indexed challengeID, address indexed creator, bytes32 wasmHash, bytes32 inputHash, bytes32 outputHash);
    event ChallengeVerified(uint256 indexed challengeID, address indexed challenger);

    struct Challenge {
        bytes32 wasmHash;
        bytes32 inputHash;
        bytes32 outputHash;
        bool exists;
        bool verified;
    }

    mapping(uint256 => Challenge) public challenges;
    uint256 public nextChallengeID;

    function createChallenge(bytes32 wasmHash, bytes32 inputHash, bytes32 outputHash) external {
        challenges[nextChallengeID] = Challenge(wasmHash, inputHash, outputHash, true, false);
        emit ChallengeCreated(nextChallengeID, msg.sender, wasmHash, inputHash, outputHash);
        nextChallengeID++;
    }

    function verifyComputation(uint256 challengeID, bytes memory wasmBytecode, bytes memory input) external {
        Challenge storage challenge = challenges[challengeID];

        require(challenge.exists, "Verification Error: Challenge ID does not exist.");
        require(!challenge.verified, "Verification Error: Challenge has already been verified.");

        require(keccak256(wasmBytecode) == challenge.wasmHash, "Verification Error: Provided Wasm bytecode does not match the stored hash for this challenge.");
        require(keccak256(input) == challenge.inputHash, "Verification Error: Provided input does not match the stored input hash for this challenge.");

        address newContract = WasmDeployerLib.deploy(wasmBytecode, "");

        (bool success, bytes memory output) = newContract.call(input);

        require(success, "Execution Error: Failed to execute the Wasm contract.");

        require(keccak256(output) == challenge.outputHash, "Output Error: Computation output does not match the expected output hash.");

        challenge.verified = true;
        emit ChallengeVerified(challengeID, msg.sender);
    }
}
