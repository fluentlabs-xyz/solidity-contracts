// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {INitroVerifier} from "../../contracts/interfaces/INitroVerifier.sol";

/**
 * @title NitroVerifierMock
 * @dev Mock for testing: always accepts verifyBlock/verifyBatch.
 */
abstract contract NitroVerifierMock is INitroVerifier {
    address public constant MOCK_ENCLAVE = address(0xE1C14E0);

    function verifyBlock(bytes32, bytes32, bytes32, bytes32, bytes calldata, bytes32[] calldata) external pure returns (address) {
        return MOCK_ENCLAVE;
    }

    function verifyBatch(bytes32, bytes32[] calldata, bytes calldata) external pure returns (address) {
        return MOCK_ENCLAVE;
    }
}
