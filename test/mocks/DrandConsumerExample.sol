// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IDrandOracle} from "../../contracts/interfaces/oracles/IDrandOracle.sol";

/**
 * @title DrandConsumerExample
 * @author Fluent Labs
 * @notice Reference integrator: a lottery whose winner is drawn from a drand round it
 *         committed to before that round's beacon existed.
 * @dev The oracle's address is the only thing this contract knows about drand. `open()`
 *      closes entry and commits, keeping the returned round; `draw()` reads it back once
 *      a publisher has put the beacon on chain, and reverts until then rather than
 *      reading a zero. Entry closing is what makes the draw fair: the set of entrants is
 *      fixed before the round exists, so nobody can join once the randomness is knowable.
 */
contract DrandConsumerExample {
    /// @dev Separates this lottery's view of a round from every other consumer's
    bytes32 internal constant DOMAIN = "lottery";

    /// @notice Entry is closed once `open()` has bound the draw to a round
    error EntryClosed();
    /// @notice The winner of this draw has already been drawn
    error AlreadyDrawn();
    /// @notice A draw needs at least one entrant
    error NoEntrants();

    IDrandOracle public immutable ORACLE;

    address[] public entrants;
    uint64 public round;
    address public winner;
    bool public drawn;

    constructor(address oracle) {
        ORACLE = IDrandOracle(oracle);
    }

    /// @notice Joins the draw; reverts once `open()` has closed entry
    function enter() external {
        if (round != 0) revert EntryClosed();
        entrants.push(msg.sender);
    }

    /// @notice Closes entry and binds the draw to a round drand has not reached yet
    /// @return The committed round
    function open() external returns (uint64) {
        if (round != 0) revert EntryClosed();
        if (entrants.length == 0) revert NoEntrants();
        round = ORACLE.commit();
        return round;
    }

    /// @notice Draws the winner from the committed round's randomness
    /// @return The winning entrant
    function draw() external returns (address) {
        if (drawn) revert AlreadyDrawn();
        bytes32 value = ORACLE.randomnessFor(round, DOMAIN);
        drawn = true;
        winner = entrants[uint256(value) % entrants.length];
        return winner;
    }
}
