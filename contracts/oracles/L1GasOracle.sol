// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IL1GasOracle} from "../interfaces/oracles/IL1GasOracle.sol";

/**
 * @title L1GasOracle
 * @author Fluent Labs
 * @notice Oracle for L1 gas price used by the Fluent L2 bridge fee formula.
 * @dev Maintains an inclusive [min, max] band in wei per gas. The relayer may widen the band so users
 *      can choose any price inside it when calling {FluentBridge-sendMessage} with `l1GasPriceForFee`.
 *      {getL1GasPrice} returns `max` so the default fee path remains the conservative upper bound.
 */
contract L1GasOracle is Ownable, IL1GasOracle {
    uint256 internal _minL1GasPrice;
    uint256 internal _maxL1GasPrice;
    address internal _submitter;

    modifier onlySubmitter() {
        require(msg.sender == _submitter, UnauthorizedSubmitter(msg.sender));
        _;
    }

    /**
     * @param submitter Hot key for band updates
     * @param minPrice Initial inclusive lower bound (wei per gas)
     * @param maxPrice Initial inclusive upper bound (wei per gas)
     */
    constructor(address submitter, uint256 minPrice, uint256 maxPrice) Ownable(msg.sender) {
        require(minPrice <= maxPrice, InvalidGasPriceRange());
        _setSubmitter(submitter);
        _minL1GasPrice = minPrice;
        _maxL1GasPrice = maxPrice;
        emit L1GasPriceRangeUpdated(minPrice, maxPrice);
    }

    function _setSubmitter(address submitter) internal {
        require(submitter != address(0), ZeroAddressNotAllowed("submitter"));
        emit SubmitterUpdated(_submitter, submitter);
        _submitter = submitter;
    }

    function _setRange(uint256 minPrice, uint256 maxPrice) internal {
        require(minPrice <= maxPrice, InvalidGasPriceRange());
        _minL1GasPrice = minPrice;
        _maxL1GasPrice = maxPrice;
        emit L1GasPriceRangeUpdated(minPrice, maxPrice);
    }

    /// @inheritdoc IL1GasOracle
    function updateL1GasPriceRange(uint256 minPrice, uint256 maxPrice) external override onlySubmitter {
        _setRange(minPrice, maxPrice);
    }

    /// @inheritdoc IL1GasOracle
    function updateL1GasPrice(uint256 gasPrice) external override onlySubmitter {
        _setRange(gasPrice, gasPrice);
    }

    /// @inheritdoc IL1GasOracle
    function setL1GasPriceRange(uint256 minPrice, uint256 maxPrice) external override onlyOwner {
        _setRange(minPrice, maxPrice);
    }

    /// @inheritdoc IL1GasOracle
    function setL1GasPrice(uint256 gasPrice) external override onlyOwner {
        _setRange(gasPrice, gasPrice);
    }

    /// @inheritdoc IL1GasOracle
    function setSubmitter(address submitter) external override onlyOwner {
        _setSubmitter(submitter);
    }

    /// @inheritdoc IL1GasOracle
    function getL1GasPrice() external view override returns (uint256) {
        return _maxL1GasPrice;
    }

    /// @inheritdoc IL1GasOracle
    function getL1GasPriceRange() external view override returns (uint256 minPrice, uint256 maxPrice) {
        return (_minL1GasPrice, _maxL1GasPrice);
    }

    /// @inheritdoc IL1GasOracle
    function isL1GasPriceInRange(uint256 price) external view override returns (bool) {
        return price >= _minL1GasPrice && price <= _maxL1GasPrice;
    }

    /// @inheritdoc IL1GasOracle
    function getSubmitter() external view override returns (address) {
        return _submitter;
    }
}
