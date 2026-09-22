// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {DrandOracle} from "../../contracts/oracles/DrandOracle.sol";

/// @dev A next implementation: same storage, one more body, so a test can tell it from V1.
contract DrandOracleV2Mock is DrandOracle {
    function version() external pure returns (uint256) {
        return 2;
    }
}
