// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {INitroEnclaveVerifier} from "../../../contracts/interfaces/INitroEnclaveVerifier.sol";

/// @dev Stub Nitro verifier that always passes all checks.
contract MockNitroVerifier is INitroEnclaveVerifier {
    function isAttestationVerified() external pure returns (bool) {
        return true;
    }

    function enclaveAddress() external pure returns (address) {
        return address(0);
    }

    function verifyBatch(bytes32, bytes32[] calldata, bytes32) external pure returns (bool) {
        return true;
    }

    function verifyBlock(bytes32, bytes32, bytes32, bytes32, bytes32, bytes32[] calldata) external pure returns (bool) {
        return true;
    }
}
