// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FluentBridge} from "../FluentBridge.sol";

import {IFluentBridge, IFluentBridgeRead} from "../../interfaces/bridge/IFluentBridge.sol";
import {IL1BlockOracle} from "../../interfaces/oracles/IL1BlockOracle.sol";
import {IL2FluentBridge} from "../../interfaces/bridge/IL2FluentBridge.sol";
import {IL1GasOracle} from "../../interfaces/oracles/IL1GasOracle.sol";

/**
 * @title L2FluentBridge
 * @author Fluent Labs
 * @dev L2 bridge contract lives on Fluent chain.
 */
contract L2FluentBridge is FluentBridge, IL2FluentBridge {
    // ============ Constants ============

    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.L2FluentBridgeStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant L2_FLUENT_BRIDGE_STORAGE_LOCATION = 0x87bc3410b506da535d5d599e04bd2f08b89897a5d89e1855acbd7567af23bd00;

    // ============ Storage ============

    /**
     * @dev L2 fee computation parameters. The formula is:
     *      cost = (l1GasPrice * scalarGasPrice / 1e18) + overheadGasPrice
     */
    struct GasPriceConfig {
        /// @dev Fixed gas cost added to every fee computation (in wei).
        uint256 _overheadGasPrice;
        /// @dev Multiplier applied to L1 gas price (18-decimal fixed-point, e.g. 1.5x = 1.5e18).
        uint256 _scalarGasPrice;
        /// @dev Assumed L1 gas units for fee calculation.
        uint256 _l1GasLimit;
    }

    /**
     * @dev ERC-7201 namespaced storage for L2-specific bridge state.
     */
    struct L2FluentBridgeStorage {
        /// @dev L1 blocks after which an undelivered message is eligible for rollback (0 = disabled).
        uint256 _receiveMessageDeadline;
        /// @dev Oracle providing the latest L1 block number on L2.
        address _l1BlockOracle;
        /// @dev Oracle providing the latest L1 gas price on L2.
        address _l1GasPriceOracle;
        /// @dev Fee computation parameters for outbound messages.
        GasPriceConfig _gasPriceConfig;
        /// @dev Reserved for future storage fields.
        uint256[50] __gap;
    }

    // ============ Storage accessor ============

    /**
     * @dev Returns the ERC-7201 storage pointer for L2-specific bridge state.
     */
    function _getL2FluentBridgeStorage() private pure returns (L2FluentBridgeStorage storage $) {
        assembly ("memory-safe") {
            $.slot := L2_FLUENT_BRIDGE_STORAGE_LOCATION
        }
    }

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Prevent the implementation contract from being initialized directly
        _disableInitializers();
    }

    // ============ Initializer ============

    /**
     * @notice Initializes the L2 bridge with base config, rollback deadline, oracles, gas config, and fee treasury.
     */
    function initialize(
        bytes calldata data,
        uint256 receiveMessageDeadline,
        address l1BlockOracle,
        address l1GasPriceOracle,
        uint256 overheadGasPrice,
        uint256 scalarGasPrice,
        uint256 l1GasLimit,
        address feeTreasury
    ) external initializer {
        // Decode base config (admin, pauser, relayer, other bridge) and init OZ modules
        __FluentBridgeStorage_init(data);

        // Max L1 blocks before an undelivered message becomes eligible for rollback
        _setReceiveMessageDeadline(receiveMessageDeadline);
        // Oracle the bridge queries to learn the latest L1 block number on L2
        _setL1BlockOracle(l1BlockOracle);
        // Oracle providing L1 gas price for outbound fee calculation
        _setL1GasPriceOracle(l1GasPriceOracle);
        // Set the three-part fee formula: overhead + (l1GasPrice * scalar / 1e18)
        _setGasPriceConfig(overheadGasPrice, scalarGasPrice, l1GasLimit);
        // Address that collects send fees — must be non-zero
        _setFeeTreasury(feeTreasury);
    }

    // ============ Fee logic ============

    /// @inheritdoc FluentBridge
    function _chargeSendFee() internal override returns (uint256) {
        // Compute the fee based on the current L1 gas price and config parameters
        uint256 fee = getSentMessageFee();
        if (fee > 0) {
            // Treasury must be configured before fees can be collected
            address treasury = getFeeTreasury();
            require(treasury != address(0), ZeroAddressNotAllowed("feeTreasury"));
            // Transfer fee from msg.value to the treasury; reverts if the call fails
            (bool success, ) = treasury.call{value: fee}("");
            require(success, FailedToDeductFee());
        }
        // Return the fee so the caller can deduct it from the cross-chain value
        return fee;
    }

    /// @inheritdoc IFluentBridgeRead
    function getSentMessageFee() public view override returns (uint256) {
        // Total fee = assumed L1 gas units * per-unit cost (scalar-adjusted L1 price + overhead)
        return getL1GasLimit() * _calculateGasCost();
    }

    // ============ Receive hooks ============

    /// @inheritdoc FluentBridge
    /// @dev Checks if the message has exceeded the rollback deadline. If so, marks it
    ///      Failed and emits {RollbackMessage} (included in L2BlockHeader.withdrawalRoot
    ///      for later proof-based rollback on L1). Returns false to skip execution.
    function _beforeReceiveMessage(
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 messageNonce,
        bytes calldata message
    ) internal override returns (bool) {
        // blockNumber is the L1 block at which the message was sent; must be non-zero
        require(blockNumber > 0, ZeroValueNotAllowed("blockNumber"));

        // Fetch the latest known L1 block number from the on-chain oracle
        uint256 l1BlockNumber = IL1BlockOracle(getL1BlockOracle()).getL1BlockNumber();

        // Reconstruct the message hash to record the outcome in storage
        bytes32 messageHash = keccak256(_encodeMessage(from, to, value, chainId, blockNumber, messageNonce, message));
        // Check if enough L1 blocks have passed since the message was sent
        // If the deadline has expired, the message is marked Failed and a rollback is emitted
        if (l1BlockNumber >= blockNumber && l1BlockNumber - blockNumber >= getReceiveMessageDeadline()) {
            // Mark as Failed so it cannot be executed later
            _getFluentBridgeStorage()._receivedMessage[messageHash] = IFluentBridge.MessageStatus.Failed;
            // RollbackMessage is included in the L2 block's withdrawalRoot,
            // enabling proof-based refund on L1 via rollbackMessageWithProof
            emit RollbackMessage(messageHash, block.number);
            emit ReceivedMessage(messageHash, false, "");
            // Return false to skip message execution in the caller
            return false;
        }
        // Deadline not exceeded — allow normal execution to proceed
        return true;
    }

    // ============ Views ============

    /// @inheritdoc IL2FluentBridge
    function getL1BlockOracle() public view returns (address) {
        // Read from ERC-7201 namespaced storage via the storage accessor
        return _getL2FluentBridgeStorage()._l1BlockOracle;
    }

    /// @notice Returns the L1 gas price oracle address.
    function getL1GasPriceOracle() public view returns (address) {
        // Read from ERC-7201 namespaced storage via the storage accessor
        return _getL2FluentBridgeStorage()._l1GasPriceOracle;
    }

    /// @inheritdoc IL2FluentBridge
    function getReceiveMessageDeadline() public view returns (uint256) {
        // Returns the number of L1 blocks after which messages become eligible for rollback
        return _getL2FluentBridgeStorage()._receiveMessageDeadline;
    }

    /// @notice Returns the current gas price configuration.
    function getGasPriceConfig() public view returns (GasPriceConfig memory) {
        // Returns a memory copy of the three-field fee config struct
        return _getL2FluentBridgeStorage()._gasPriceConfig;
    }

    /// @notice Returns the assumed L1 gas units used for fee calculation.
    function getL1GasLimit() public view returns (uint256) {
        // Reads via getGasPriceConfig() which loads the full struct into memory
        return getGasPriceConfig()._l1GasLimit;
    }

    /** @dev Computes the L1 gas cost component of the send fee using oracle price and config. */
    function _calculateGasCost() internal view returns (uint256) {
        // Cache config in memory to avoid repeated SLOAD
        GasPriceConfig memory gasPriceConfig = getGasPriceConfig();
        // Query the oracle for the current L1 base fee (in wei per gas unit)
        uint256 l1GasPrice = IL1GasOracle(getL1GasPriceOracle()).getL1GasPrice();
        // Formula: (l1GasPrice * scalarGasPrice) / 1e18 + overheadGasPrice
        // 1e18 denominator enables fractional scaling (e.g. 1.5x = 1.5e18)
        // overheadGasPrice adds a fixed base cost independent of L1 conditions
        return ((l1GasPrice * gasPriceConfig._scalarGasPrice)) / 1e18 + gasPriceConfig._overheadGasPrice;
    }

    // ============ Admin ============

    /**
     * @notice Update the address of the L1 block oracle used for rollback deadline checks.
     * @param l1BlockOracle The address of the L1 block oracle.
     */
    function setL1BlockOracle(address l1BlockOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Admin-gated — delegates to internal setter with validation
        _setL1BlockOracle(l1BlockOracle);
    }

    /** @dev Stores the L1 block oracle. Zero address allowed only when deadline is disabled. */
    function _setL1BlockOracle(address l1BlockOracle) internal {
        // When the rollback deadline is active, the oracle is required for deadline checks
        // Zero address is only allowed when the deadline is disabled (== 0)
        if (getReceiveMessageDeadline() != 0) require(l1BlockOracle != address(0), ZeroAddressNotAllowed("l1BlockOracle"));
        // Emit before writing so event carries both old and new addresses
        emit L1BlockOracleUpdated(getL1BlockOracle(), l1BlockOracle);
        // Persist the new oracle in ERC-7201 namespaced storage
        _getL2FluentBridgeStorage()._l1BlockOracle = l1BlockOracle;
    }

    /// @notice Updates the L1 gas price oracle address.
    function setL1GasPriceOracle(address l1GasPriceOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Admin-gated — delegates to internal setter with validation
        _setL1GasPriceOracle(l1GasPriceOracle);
    }

    /** @dev Validates and stores the L1 gas price oracle. Reverts on zero address. */
    function _setL1GasPriceOracle(address l1GasPriceOracle) internal {
        // Gas price oracle is always required — fee computation depends on it
        require(l1GasPriceOracle != address(0), ZeroAddressNotAllowed("l1GasPriceOracle"));
        // Emit old/new pair for off-chain monitoring and indexing
        emit L1GasPriceOracleUpdated(getL1GasPriceOracle(), l1GasPriceOracle);
        // Persist the new oracle in ERC-7201 namespaced storage
        _getL2FluentBridgeStorage()._l1GasPriceOracle = l1GasPriceOracle;
    }

    /// @notice Updates the gas price configuration.
    function setGasPriceConfig(uint256 overheadGasPrice, uint256 scalarGasPrice, uint256 l1GasLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Admin-gated — all three parameters are updated atomically
        _setGasPriceConfig(overheadGasPrice, scalarGasPrice, l1GasLimit);
    }

    /** @dev Stores gas price parameters and emits update event. */
    function _setGasPriceConfig(uint256 overheadGasPrice, uint256 scalarGasPrice, uint256 l1GasLimit) internal {
        // Load storage pointer once to batch writes and emit old values
        GasPriceConfig storage $ = _getL2FluentBridgeStorage()._gasPriceConfig;
        // Emit before writing so the event contains both old and new values
        emit GasPriceConfigUpdated($._overheadGasPrice, overheadGasPrice, $._scalarGasPrice, scalarGasPrice);
        // Update all three fee parameters atomically
        $._overheadGasPrice = overheadGasPrice;
        $._scalarGasPrice = scalarGasPrice;
        $._l1GasLimit = l1GasLimit;
    }

    /// @inheritdoc IL2FluentBridge
    function setReceiveMessageDeadline(uint256 receiveMessageDeadline) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Admin-gated — controls the rollback eligibility window
        _setReceiveMessageDeadline(receiveMessageDeadline);
    }

    /** @dev Stores the rollback deadline. Reverts on zero value. */
    function _setReceiveMessageDeadline(uint256 receiveMessageDeadline) internal {
        // Zero deadline would disable rollback entirely, which is not allowed
        require(receiveMessageDeadline > 0, InvalidWindowConfig("receiveMessageDeadline must be greater than 0"));
        emit ReceiveMessageDeadlineUpdated(getReceiveMessageDeadline(), receiveMessageDeadline);
        _getL2FluentBridgeStorage()._receiveMessageDeadline = receiveMessageDeadline;
    }
}
