// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IL1GasOracle} from "../interfaces/oracles/IL1GasOracle.sol";

/**
 * @title L1GasOracle
 * @author Fluent Labs
 * @notice Oracle contract for the L1 gas price
 * @dev Provides a function to get the current L1 gas price and is used in the Fluent bridge
 *      to send messages with the correct gas price.
 */
contract L1GasOracle is Ownable, IL1GasOracle {
    /// @dev The current L1 gas price
    uint256 internal _l1GasPrice;

    /// @dev Hot key address authorized to submit gas price updates.
    address internal _submitter;

    /**
     * @dev Restricts to the authorized submitter address.
     */
    modifier onlySubmitter() {
        require(msg.sender == _submitter, UnauthorizedSubmitter(msg.sender));
        _;
    }

    /**
     * @dev Sets the contract owner to `msg.sender` and configures the initial submitter.
     */
    constructor(address submitter) Ownable(msg.sender) {
        _setSubmitter(submitter);
    }

    // ============ Submitter ============

    /// @inheritdoc IL1GasOracle
    function updateL1GasPrice(uint256 gasPrice) external override onlySubmitter {
        // no monotonicity constraint: gas prices can fluctuate in either direction
        _l1GasPrice = gasPrice;
        emit L1GasPriceUpdated(gasPrice);
    }

    // ============ Owner ============

    /// @inheritdoc IL1GasOracle
    function setL1GasPrice(uint256 gasPrice) external onlyOwner {
        // owner bypass allows direct price override for emergency corrections
        _l1GasPrice = gasPrice;
        emit L1GasPriceUpdated(gasPrice);
    }

    /// @inheritdoc IL1GasOracle
    function setSubmitter(address submitter) external override onlyOwner {
        _setSubmitter(submitter);
    }

    /**
     * @dev Validates and stores the submitter address. Reverts on zero address.
     */
    function _setSubmitter(address submitter) internal {
        require(submitter != address(0), ZeroAddressNotAllowed("submitter"));
        emit SubmitterUpdated(_submitter, submitter);
        _submitter = submitter;
    }

    // ============ Views ============

    /// @inheritdoc IL1GasOracle
    function getL1GasPrice() external view override returns (uint256) {
        return _l1GasPrice;
    }

    /// @inheritdoc IL1GasOracle
    function getSubmitter() external view override returns (address) {
        return _submitter;
    }
}
