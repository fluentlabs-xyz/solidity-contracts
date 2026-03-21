// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISP1Verifier} from "../../contracts/interfaces/ISP1Verifier.sol";

/// @dev Stub SP1 verifier that always succeeds (never reverts).
contract MockSp1Verifier is ISP1Verifier {
    function verifyProof(bytes32, bytes calldata, bytes calldata) external pure {}
}
