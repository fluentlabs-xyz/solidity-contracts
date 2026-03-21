// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ISP1Verifier} from "../../contracts/interfaces/ISP1Verifier.sol";

contract VerifierMock is ISP1Verifier {
    constructor() {}

    function verifyProof(bytes32 programVKey, bytes calldata publicValues, bytes calldata proofBytes) external view {}
}
