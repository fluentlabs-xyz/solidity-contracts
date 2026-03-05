// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IRollupVerifier} from "../interfaces/IRollupVerifier.sol";

contract BatchVerifierMock is IRollupVerifier {
    constructor() {}

    function verifyAggregateProof(uint256 batchIndex, bytes calldata aggregationProof, bytes32 publicInputHash) external view {}
}
