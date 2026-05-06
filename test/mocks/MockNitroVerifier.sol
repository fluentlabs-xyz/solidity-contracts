// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {INitroVerifier} from "contracts/interfaces/verifiers/INitroVerifier.sol";

/// @dev Stub Nitro verifier that always passes all checks.
contract MockNitroVerifier is INitroVerifier {
    function verifyBatch(bytes32, bytes32[] calldata, bytes calldata) external pure returns (address) {
        return address(1);
    }
}
