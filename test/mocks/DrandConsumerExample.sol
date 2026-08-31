// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IDrandOracle} from "../../contracts/interfaces/oracles/IDrandOracle.sol";

/**
 * @title DrandConsumerExample
 * @author Fluent Labs
 * @notice Reference integrator: a lottery whose winner is drawn from a drand round it
 *         committed to before that round's beacon existed.
 * @dev The oracle's address is the only thing this contract knows about drand. `open()`
 *      commits and keeps the returned round; `draw()` reads it back once a publisher has
 *      put the beacon on chain, and reverts until then rather than reading a zero.
 */
contract DrandConsumerExample {
    /// @dev Separates this lottery's view of a round from every other consumer's
    bytes32 internal constant DOMAIN = "lottery";

    IDrandOracle public immutable ORACLE;

    address[] public entrants;
    uint64 public round;
    address public winner;

    constructor(address oracle) {
        ORACLE = IDrandOracle(oracle);
    }

    /// @notice Joins the current draw
    function enter() external {
        entrants.push(msg.sender);
    }

    /// @notice Closes entry and binds the draw to a round drand has not reached yet
    /// @return The committed round
    function open() external returns (uint64) {
        round = ORACLE.commit();
        return round;
    }

    /// @notice Draws the winner from the committed round's randomness
    /// @return The winning entrant
    function draw() external returns (address) {
        bytes32 value = ORACLE.randomnessFor(round, DOMAIN);
        winner = entrants[uint256(value) % entrants.length];
        return winner;
    }
}
