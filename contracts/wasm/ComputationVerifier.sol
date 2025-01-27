// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {WasmDeployerLib} from "./WasmDeployerLib.sol";

/// Thrown when the specified challenge ID does not exist.
error ChallengeDoesNotExist();
/// Thrown if the challenge is already verified.
error ChallengeAlreadyVerified();
/// Thrown when Wasm bytecode does not match the stored hash.
error WasmBytecodeMismatch();
/// Thrown if input data does not match the stored hash.
error InputMismatch();
/// Thrown when computed output does not match the expected hash.
error OutputMismatch();
/// Thrown if execution of the Wasm contract fails.
error WasmExecutionFailed(bytes output);

contract ComputationVerifier {
    event ChallengeCreated(uint256 indexed challengeID, address indexed creator, bytes32 wasmHash, bytes32 inputHash, bytes32 outputHash);
    event ChallengeVerified(uint256 indexed challengeID, address indexed challenger);

    struct Challenge {
        bytes32 wasmHash;
        bytes32 inputHash;
        bytes32 outputHash;
        bool verified;
    }

    mapping(uint256 => Challenge) public challenges;
    uint256 public nextChallengeID;

    function createChallenge(bytes32 wasmHash, bytes32 inputHash, bytes32 outputHash) external {
        challenges[nextChallengeID] = Challenge(wasmHash, inputHash, outputHash, false);
        emit ChallengeCreated(nextChallengeID, msg.sender, wasmHash, inputHash, outputHash);
        nextChallengeID++;
    }

    function verifyComputation(uint256 challengeID, bytes memory wasmBytecode, bytes memory input) external {
        Challenge storage challenge = challenges[challengeID];

        require(challenge.wasmHash != bytes32(0), ChallengeDoesNotExist());
        require(!challenge.verified, ChallengeAlreadyVerified());
        require(keccak256(wasmBytecode) == challenge.wasmHash, WasmBytecodeMismatch());
        require(keccak256(input) == challenge.inputHash, InputMismatch());

        address newContract = WasmDeployerLib.deploy(wasmBytecode, "");
        (bool success, bytes memory output) = newContract.call(input);
        require(success, WasmExecutionFailed(output));
        require(keccak256(output) == challenge.outputHash, OutputMismatch());

        challenge.verified = true;
        emit ChallengeVerified(challengeID, msg.sender);
    }
}
