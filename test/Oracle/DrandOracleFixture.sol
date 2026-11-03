// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DrandOracle} from "../../contracts/oracles/DrandOracle.sol";

/// @dev Deploys the oracle the way the chain sees it: an implementation behind a UUPS proxy,
///      with the two roles on two accounts.
abstract contract DrandOracleFixture is Test {
    address internal oracleAdmin = makeAddr("oracleAdmin");
    address internal oracleEmergency = makeAddr("oracleEmergency");

    function _deployOracle() internal returns (DrandOracle) {
        address implementation = address(new DrandOracle());
        return DrandOracle(
            address(
                new ERC1967Proxy(implementation, abi.encodeCall(DrandOracle.initialize, (oracleAdmin, oracleEmergency)))
            )
        );
    }
}
