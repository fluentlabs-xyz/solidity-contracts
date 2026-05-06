// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IL1BlockOracle} from "../../contracts/interfaces/oracles/IL1BlockOracle.sol";
import {L1BlockOracle} from "../../contracts/oracles/L1BlockOracle.sol";

contract L1BlockOracleTest is Test {
    address internal owner;
    address internal submitter;
    address internal user = makeAddr("user");
    L1BlockOracle internal oracle;

    function setUp() public {
        owner = address(this);
        submitter = makeAddr("submitter");
        oracle = new L1BlockOracle(submitter);
    }

    function test_updateL1BlockNumber_isMonotonic() public {
        vm.prank(submitter);
        oracle.updateL1BlockNumber(100);

        vm.expectRevert(abi.encodeWithSelector(IL1BlockOracle.BlockNotMonotonic.selector, uint256(100), uint256(99)));
        vm.prank(submitter);
        oracle.updateL1BlockNumber(99);
    }

    function test_updateL1BlockNumber_allowsAdvancing() public {
        vm.expectEmit(true, false, false, true, address(oracle));
        emit IL1BlockOracle.L1BlockNumberUpdated(100);
        vm.prank(submitter);
        oracle.updateL1BlockNumber(100);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit IL1BlockOracle.L1BlockNumberUpdated(101);
        vm.prank(submitter);
        oracle.updateL1BlockNumber(101);

        assertEq(oracle.getL1BlockNumber(), 101);
    }

    function test_RevertIf_updateL1BlockNumber_callerNotSubmitter() public {
        vm.expectRevert(abi.encodeWithSelector(IL1BlockOracle.UnauthorizedSubmitter.selector, user));
        vm.prank(user);
        oracle.updateL1BlockNumber(100);
    }

    function test_setL1BlockNumber_ownerCanSetBackwards() public {
        vm.prank(submitter);
        oracle.updateL1BlockNumber(100);
        oracle.setL1BlockNumber(50);
        assertEq(oracle.getL1BlockNumber(), 50, "owner should bypass monotonicity");
    }

    function test_RevertIf_setL1BlockNumber_callerNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        oracle.setL1BlockNumber(100);
    }

    function test_RevertIf_setL1BlockNumber_zero() public {
        vm.expectRevert(abi.encodeWithSelector(IL1BlockOracle.L1BlockNumberZeroNotAllowed.selector));
        oracle.setL1BlockNumber(0);
    }

    function test_RevertIf_setL1BlockNumber_exceedsMax() public {
        uint256 maxBn = oracle.MAX_L1_BLOCK_NUMBER();
        vm.expectRevert(abi.encodeWithSelector(IL1BlockOracle.L1BlockNumberTooLarge.selector, maxBn + 1, maxBn));
        oracle.setL1BlockNumber(maxBn + 1);
    }

    function test_RevertIf_updateL1BlockNumber_zero() public {
        vm.expectRevert(abi.encodeWithSelector(IL1BlockOracle.L1BlockNumberZeroNotAllowed.selector));
        vm.prank(submitter);
        oracle.updateL1BlockNumber(0);
    }

    function test_RevertIf_updateL1BlockNumber_exceedsMax() public {
        vm.startPrank(submitter);
        oracle.updateL1BlockNumber(oracle.MAX_L1_BLOCK_NUMBER());
        uint256 maxBn = oracle.MAX_L1_BLOCK_NUMBER();
        vm.expectRevert(abi.encodeWithSelector(IL1BlockOracle.L1BlockNumberTooLarge.selector, maxBn + 1, maxBn));
        oracle.updateL1BlockNumber(maxBn + 1);
        vm.stopPrank();
    }

    function test_setSubmitter_updatesAndEmits() public {
        address newSubmitter = makeAddr("newSubmitter");
        vm.expectEmit(true, true, false, true, address(oracle));
        emit IL1BlockOracle.SubmitterUpdated(submitter, newSubmitter);
        oracle.setSubmitter(newSubmitter);
        assertEq(oracle.getSubmitter(), newSubmitter, "submitter should be updated");
        vm.prank(newSubmitter);
        oracle.updateL1BlockNumber(1);
        assertEq(oracle.getL1BlockNumber(), 1, "new submitter should work");
    }

    function test_RevertIf_setSubmitter_zeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IL1BlockOracle.ZeroAddressNotAllowed.selector, "submitter"));
        oracle.setSubmitter(address(0));
    }
}
