// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IL1BlockOracle} from "../../contracts/interfaces/IL1BlockOracle.sol";
import {L1BlockOracle} from "../../contracts/oracle/L1BlockOracle.sol";

contract L1BlockOracleTest is Test {
    L1BlockOracle internal oracle;

    function setUp() public {
        oracle = new L1BlockOracle();
    }

    function test_updateL1BlockNumber_isMonotonic() public {
        oracle.updateL1BlockNumber(100);

        vm.expectRevert(abi.encodeWithSelector(IL1BlockOracle.L1BlockNumberDecreased.selector, 100, 99));
        oracle.updateL1BlockNumber(99);
    }

    function test_updateL1BlockNumber_allowsAdvancing() public {
        oracle.updateL1BlockNumber(100);
        oracle.updateL1BlockNumber(101);

        assertEq(oracle.getL1BlockNumber(), 101);
    }
}
