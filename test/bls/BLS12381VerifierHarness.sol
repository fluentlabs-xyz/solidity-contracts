// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {BLS12381Verifier} from "../../contracts/libraries/BLS12381Verifier.sol";

/// @notice Test-only: exposes internal `_hashToG1` for the conformance pin
///         without widening the production verifier ABI.
contract BLS12381VerifierHarness is BLS12381Verifier {
    function hashToG1Exposed(bytes calldata input, bytes calldata dst) external view returns (bytes memory) {
        return _hashToG1(input, dst);
    }
}
