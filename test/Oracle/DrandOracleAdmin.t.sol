// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IDrandOracle} from "../../contracts/interfaces/oracles/IDrandOracle.sol";
import {DrandOracle} from "../../contracts/oracles/DrandOracle.sol";

contract DrandOracleAdminTest is Test {
    /// drand quicknet round 8191 is live at this timestamp.
    uint256 internal constant NOW = 1_692_827_937;

    DrandOracle internal oracle;
    address internal user = makeAddr("user");

    function setUp() public {
        vm.warp(NOW);
        oracle = new DrandOracle(address(this));
    }

    /// R12: the offset is inside its range from the contract's first block —
    /// never at a storage default that would let a commit land on a published round.
    function test_constructor_startsAtTheFloor() public {
        uint64 floorValue = oracle.MIN_FUTURE_ROUNDS_FLOOR();
        assertEq(oracle.minFutureRounds(), floorValue, "offset must start at the floor");

        uint64 tooSoon = oracle.currentRound() + floorValue - 1;
        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundTooSoon.selector, tooSoon, tooSoon + 1));
        vm.prank(user);
        oracle.commitTo(tooSoon);
    }

    /// R12: the role holder changes the offset, and the change binds the commit path.
    function test_setMinFutureRounds_takesEffectOnCommit() public {
        vm.expectEmit(false, false, false, true, address(oracle));
        emit IDrandOracle.MinFutureRoundsUpdated(oracle.minFutureRounds(), 5);
        oracle.setMinFutureRounds(5);

        uint64 expected = oracle.currentRound() + 5;
        vm.prank(user);
        uint64 committed = oracle.commit();
        assertEq(committed, expected, "commit must use the new offset");
    }

    /// R12: no one but the role holder changes it.
    function test_RevertIf_setMinFutureRounds_callerNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        oracle.setMinFutureRounds(5);
    }

    /// R12: not even the role holder can put it outside its range.
    function test_RevertIf_setMinFutureRounds_outsideRange() public {
        uint64 floorValue = oracle.MIN_FUTURE_ROUNDS_FLOOR();
        uint64 maxValue = oracle.MAX_FUTURE_ROUNDS();

        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.MinFutureRoundsTooLow.selector, floorValue - 1, floorValue));
        oracle.setMinFutureRounds(floorValue - 1);

        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.MinFutureRoundsTooHigh.selector, maxValue + 1, maxValue));
        oracle.setMinFutureRounds(maxValue + 1);
    }
}
