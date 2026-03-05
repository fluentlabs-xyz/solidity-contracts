// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IVerifier} from "../interfaces/IVerifier.sol";

contract VerifierMock is IVerifier {
    constructor() {}

    function verifyProof(bytes32 programVKey, bytes calldata publicValues, bytes calldata proofBytes) external view {}
}
