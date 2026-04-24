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
        oracle = new L1GasOracle(submitter, 100);
    }

    function test_updateL1GasPrice_submitter() public {
        vm.prank(submitter);
        oracle.updateL1GasPrice(7 gwei);
        assertEq(oracle.getL1GasPrice(), 7 gwei);
    }

    function test_RevertIf_updateL1GasPrice_callerNotSubmitter() public {
        vm.expectRevert(abi.encodeWithSelector(IL1GasOracle.UnauthorizedSubmitter.selector, user));
        vm.prank(user);
        oracle.updateL1GasPrice(1);
    }

    function test_setL1GasPrice_owner() public {
        oracle.setL1GasPrice(11 gwei);
        assertEq(oracle.getL1GasPrice(), 11 gwei);
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

    function test_RevertIf_constructor_zeroWindow() public {
        vm.expectRevert(IL1GasOracle.InvalidGasPriceWindow.selector);
        new L1GasOracle(submitter, 0);
    }

    function test_RevertIf_constructor_windowExceedsUint32() public {
        vm.expectRevert(IL1GasOracle.InvalidGasPriceWindow.selector);
        new L1GasOracle(submitter, uint256(type(uint32).max) + 1);
    }

    function test_queuedUpdateActivatesOnlyAfterWindow() public {
        vm.prank(submitter);
        oracle.updateL1GasPrice(10 gwei);
        assertEq(oracle.getL1GasPrice(), 10 gwei);

        vm.prank(submitter);
        oracle.updateL1GasPrice(99 gwei);
        assertEq(oracle.getL1GasPrice(), 10 gwei);

        vm.warp(block.timestamp + 100);
        assertEq(oracle.getL1GasPrice(), 99 gwei);
    }

    function test_getGasPriceCommitment_tracksWindow() public {
        vm.prank(submitter);
        oracle.updateL1GasPrice(5 gwei);
        (uint256 p, uint256 until) = oracle.getGasPriceCommitment();
        assertEq(p, 5 gwei);
        assertEq(until, block.timestamp + 100);

        vm.prank(submitter);
        oracle.updateL1GasPrice(20 gwei);
        (p, until) = oracle.getGasPriceCommitment();
        assertEq(p, 5 gwei);
        assertEq(until, block.timestamp + 100);

        vm.warp(block.timestamp + 100);
        (p, until) = oracle.getGasPriceCommitment();
        assertEq(p, 20 gwei);
        // At the boundary we are at `virtualEpochStart`; the next commitment edge is one full window ahead.
        assertEq(until, block.timestamp + oracle.getGasPriceWindow());
    }

    function test_setGasPriceWindow() public {
        oracle.setGasPriceWindow(200);
        assertEq(oracle.getGasPriceWindow(), 200);
    }

    function test_RevertIf_setGasPriceWindow_zero() public {
        vm.expectRevert(IL1GasOracle.InvalidGasPriceWindow.selector);
        oracle.setGasPriceWindow(0);
    }

    function test_RevertIf_setGasPriceWindow_callerNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        oracle.setGasPriceWindow(50);
    }
}
