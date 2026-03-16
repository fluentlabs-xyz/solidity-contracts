// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {INitroEnclaveVerifier} from "../interfaces/INitroEnclaveVerifier.sol";

/**
 * @title NitroEnclaveVerifierMock
 * @dev Mock for testing: always accepts verifyBlock and reports attestation verified.
 */
abstract contract NitroEnclaveVerifierMock is INitroEnclaveVerifier {
    address public constant MOCK_ENCLAVE = address(0xE1C14E0);

    function isAttestationVerified() external pure returns (bool) {
        return true;
    }

    function enclaveAddress() external pure returns (address) {
        return MOCK_ENCLAVE;
    }

    function verifyBlock(bytes32, bytes32, bytes32, bytes32, bytes calldata) external pure returns (bool) {
        return true;
    }
}
