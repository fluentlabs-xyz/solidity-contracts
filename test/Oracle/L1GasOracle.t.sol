// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IL1GasOracle} from "../../contracts/interfaces/oracles/IL1GasOracle.sol";
import {L1GasOracle} from "../../contracts/oracles/L1GasOracle.sol";

contract L1GasOracleTest is Test {
    address internal owner;
    address internal submitter;
    address internal user = makeAddr("user");
    L1GasOracle internal oracle;

    function setUp() public {
        owner = address(this);
        submitter = makeAddr("submitter");
        oracle = new L1GasOracle(submitter, 5 gwei, 10 gwei);
    }

    function test_constructor_storesRange() public view {
        (uint256 minP, uint256 maxP) = oracle.getL1GasPriceRange();
        assertEq(minP, 5 gwei);
        assertEq(maxP, 10 gwei);
        assertEq(oracle.getL1GasPrice(), 10 gwei);
    }

    function test_RevertIf_constructor_invalidRange() public {
        vm.expectRevert(IL1GasOracle.InvalidGasPriceRange.selector);
        new L1GasOracle(submitter, 10 gwei, 5 gwei);
    }

    function test_updateL1GasPriceRange_submitter() public {
        vm.prank(submitter);
        oracle.updateL1GasPriceRange(1 gwei, 20 gwei);
        (uint256 minP, uint256 maxP) = oracle.getL1GasPriceRange();
        assertEq(minP, 1 gwei);
        assertEq(maxP, 20 gwei);
        assertEq(oracle.getL1GasPrice(), 20 gwei);
    }

    function test_updateL1GasPrice_collapsesBand() public {
        vm.prank(submitter);
        oracle.updateL1GasPrice(7 gwei);
        (uint256 minP, uint256 maxP) = oracle.getL1GasPriceRange();
        assertEq(minP, 7 gwei);
        assertEq(maxP, 7 gwei);
    }

    function test_isL1GasPriceInRange() public view {
        assertTrue(oracle.isL1GasPriceInRange(7 gwei));
        assertTrue(oracle.isL1GasPriceInRange(5 gwei));
        assertTrue(oracle.isL1GasPriceInRange(10 gwei));
        assertFalse(oracle.isL1GasPriceInRange(4 gwei));
        assertFalse(oracle.isL1GasPriceInRange(11 gwei));
    }

    function test_RevertIf_updateL1GasPriceRange_callerNotSubmitter() public {
        vm.expectRevert(abi.encodeWithSelector(IL1GasOracle.UnauthorizedSubmitter.selector, user));
        vm.prank(user);
        oracle.updateL1GasPriceRange(1, 2);
    }

    function test_setL1GasPriceRange_owner() public {
        oracle.setL1GasPriceRange(11 gwei, 15 gwei);
        assertEq(oracle.getL1GasPrice(), 15 gwei);
    }

    function test_setL1GasPrice_owner() public {
        oracle.setL1GasPrice(9 gwei);
        (uint256 minP, uint256 maxP) = oracle.getL1GasPriceRange();
        assertEq(minP, 9 gwei);
        assertEq(maxP, 9 gwei);
    }

    function test_RevertIf_setL1GasPrice_callerNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        oracle.setL1GasPrice(1);
    }

    function test_setSubmitter_updatesAndEmits() public {
        address newSubmitter = makeAddr("newSubmitter");
        oracle.setSubmitter(newSubmitter);
        assertEq(oracle.getSubmitter(), newSubmitter);
        vm.prank(newSubmitter);
        oracle.updateL1GasPrice(3 gwei);
        assertEq(oracle.getL1GasPrice(), 3 gwei);
    }

    function test_RevertIf_setSubmitter_zeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IL1GasOracle.ZeroAddressNotAllowed.selector, "submitter"));
        oracle.setSubmitter(address(0));
    }
}
