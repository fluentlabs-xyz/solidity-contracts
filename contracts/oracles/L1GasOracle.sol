// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IL1GasOracle} from "../interfaces/oracles/IL1GasOracle.sol";

/**
 * @title L1GasOracle
 * @author Fluent Labs
 * @notice Oracle contract for the L1 gas price
 * @dev Provides {getL1GasPrice} for the Fluent bridge fee formula. Uses a **sliding commitment window** so the
 *      quoted price stays constant between boundaries: submitter updates queue the next value, which only affects
 *      on-chain fee reads after the current window elapses. This removes races where a user simulates against one
 *      price and their transaction reverts because the oracle moved before inclusion.
 */
contract L1GasOracle is Ownable, IL1GasOracle {
    // ============ Storage ============

    /// @dev Committed gas price for the current window (what {getL1GasPrice} returns until the window ends).
    uint256 internal _gasPrice;

    /// @dev Latest value from the submitter; becomes `_gasPrice` at the next due window boundary(ies).
    uint256 internal _queuedGasPrice;

    /// @dev Packed: `submitter` (160) | `_epochStart` (64) | `_gasPriceWindow` (32). Epoch `0` = not yet initialized.
    address internal _submitter;
    uint64 internal _epochStart;
    /// @dev Window length in seconds; fits uint32 (~136y max). {setGasPriceWindow} enforces this bound.
    uint32 internal _gasPriceWindow;

    /**
     * @dev Restricts to the authorized submitter address.
     */
    modifier onlySubmitter() {
        require(msg.sender == _submitter, UnauthorizedSubmitter(msg.sender));
        _;
    }

    /**
     * @param submitter Hot key authorized to call {updateL1GasPrice}
     * @param gasPriceWindowSeconds Minimum time between commitment changes from queued updates (must be > 0)
     */
    constructor(address submitter, uint256 gasPriceWindowSeconds) Ownable(msg.sender) {
        require(gasPriceWindowSeconds > 0 && gasPriceWindowSeconds <= type(uint32).max, InvalidGasPriceWindow());
        _gasPriceWindow = uint32(gasPriceWindowSeconds);
        _setSubmitter(submitter);
    }

    // ============ Submitter ============

    /// @inheritdoc IL1GasOracle
    function updateL1GasPrice(uint256 gasPrice) external override onlySubmitter {
        // First-ever price: commit immediately so deployments and tests get a live value without waiting a window.
        if (_epochStart == 0) {
            _gasPrice = gasPrice;
            _queuedGasPrice = gasPrice;
            _epochStart = uint64(block.timestamp);
            emit L1GasPriceUpdated(gasPrice);
            return;
        }

        _roll();
        _queuedGasPrice = gasPrice;
        emit L1GasPriceQueued(gasPrice, uint256(_epochStart) + uint256(_gasPriceWindow));
    }

    // ============ Views ============

    /// @inheritdoc IL1GasOracle
    function getL1GasPrice() external view override returns (uint256) {
        if (_epochStart == 0) return _gasPrice;

        uint256 w = uint256(_gasPriceWindow);
        if (block.timestamp - uint256(_epochStart) < w) return _gasPrice;

        return _queuedGasPrice;
    }

    /// @inheritdoc IL1GasOracle
    function getGasPriceWindow() external view returns (uint256) {
        return uint256(_gasPriceWindow);
    }

    /// @inheritdoc IL1GasOracle
    function getGasPriceCommitment() external view override returns (uint256 effectivePrice, uint256 validUntil) {
        if (_epochStart == 0) return (_gasPrice, type(uint256).max);

        uint256 w = uint256(_gasPriceWindow);
        uint256 es = uint256(_epochStart);
        uint256 elapsed = block.timestamp - es;

        if (elapsed < w) return (_gasPrice, es + w);

        uint256 n = elapsed / w;
        uint256 virtualEpochStart = es + n * w;
        return (_queuedGasPrice, virtualEpochStart + w);
    }

    /// @inheritdoc IL1GasOracle
    function getSubmitter() external view override returns (address) {
        return _submitter;
    }

    /**
     * @dev Rolls the window forward, committing `_queuedGasPrice` into `_gasPrice` for each full window that has elapsed.
     */
    function _roll() internal {
        if (_epochStart == 0) return;

        uint256 w = uint256(_gasPriceWindow);
        uint256 elapsed = block.timestamp - uint256(_epochStart);
        if (elapsed < w) return;

        uint256 n = elapsed / w;
        uint256 oldPrice = _gasPrice;
        _gasPrice = _queuedGasPrice;
        _epochStart = uint64(uint256(_epochStart) + n * w);

        if (_gasPrice != oldPrice) emit L1GasPriceUpdated(_gasPrice);
    }

    // ============ Owner ============

    /// @inheritdoc IL1GasOracle
    function setL1GasPrice(uint256 gasPrice) external onlyOwner {
        _gasPrice = gasPrice;
        _queuedGasPrice = gasPrice;
        _epochStart = uint64(block.timestamp);
        emit L1GasPriceUpdated(gasPrice);
    }

    /// @inheritdoc IL1GasOracle
    function setGasPriceWindow(uint256 newWindowSeconds) external onlyOwner {
        require(newWindowSeconds > 0 && newWindowSeconds <= type(uint32).max, InvalidGasPriceWindow());
        _roll();
        uint256 old = uint256(_gasPriceWindow);
        _gasPriceWindow = uint32(newWindowSeconds);
        emit GasPriceWindowUpdated(old, newWindowSeconds);
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
}
