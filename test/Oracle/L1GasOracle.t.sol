// SPDX-License-Identifier: MIT
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
        oracle = new L1GasOracle(submitter);
    }

    function test_updateL1GasPrice_submitter() public {
        vm.prank(submitter);
        oracle.updateL1GasPrice(7 gwei);
        assertEq(oracle.getL1GasPrice(), 7 gwei);
    }

    function test_RevertIf_updateL1GasPrice_callerNotSubmitter() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
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
}
