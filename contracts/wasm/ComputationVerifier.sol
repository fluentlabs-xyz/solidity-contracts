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
        require(challenge.exists, "challenge does not exist");
        require(!challenge.verified, "challenge already verified");
        require(keccak256(wasmBytecode) == challenge.wasmHash, "challenge wasm binary does is not good");
        require(keccak256(input) == challenge.inputHash, "input is not good");
        address newContract = WasmDeployerLib.deploy(wasmBytecode, "");
        (bool success, bytes memory output) = newContract.call(input);
        require(success, "wasm contract execution failed");
        require(keccak256(output) == challenge.outputHash, "computation output does not match expected result");

        challenge.verified = true;
        emit ChallengeVerified(challengeID, msg.sender);
    }

    function isChallengeVerified(uint256 challengeID) external view returns (bool) {
        require(challenges[challengeID].exists, "Challenge does not exist");
        return challenges[challengeID].verified;
    }
}
