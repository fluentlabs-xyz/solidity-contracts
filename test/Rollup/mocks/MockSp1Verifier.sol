// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IVerifier} from "../../../contracts/interfaces/IVerifier.sol";

/// @dev Stub SP1 verifier that always succeeds (never reverts).
contract MockSp1Verifier is IVerifier {
    function verifyProof(bytes32, bytes calldata, bytes calldata) external pure {}
}
