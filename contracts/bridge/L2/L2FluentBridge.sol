// SPDX-License-Identifier: Apache-2.0
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

    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.L2FluentBridgeStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant L2_FLUENT_BRIDGE_STORAGE_LOCATION = 0xdb789bfce4d76202a01e0604e72a2e052398264aedb278a3431997ac77ce1100;

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

    /// @custom:storage-location erc7201:Fluent.storage.L2FluentBridgeStorage
    struct L2FluentBridgeStorage {
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
     * @notice Initializes the L2 bridge with base config, oracles, gas config, and fee treasury.
     * @dev The receive-message deadline is now L1-owned and snapshotted into each outbound
     *      L1->L2 message hash at send time. L2 no longer stores or configures the deadline —
     *      it validates the committed {validUntilBlockNumber} against the L1 block oracle.
     */
    function initialize(
        bytes calldata data,
        address l1BlockOracle,
        address l1GasPriceOracle,
        uint256 overheadGasPrice,
        uint256 scalarGasPrice,
        uint256 l1GasLimit,
        address feeTreasury
    ) external initializer {
        // Decode base config (admin, pauser, relayer, other bridge) and init OZ modules
        __FluentBridgeStorage_init(data);

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

    /**
     * @inheritdoc FluentBridge
     * @dev `fee` is computed once by the base {FluentBridge-sendMessage} and passed through
     *      to avoid a second oracle read. The value matches the one used to derive `value`
     *      for the outbound message, so the transfer and the cross-chain value stay in sync
     *      even if the oracle state were to change between calls (impossible within a single
     *      tx, but defensively consistent).
     */
    function _chargeSendFee(uint256 fee) internal override {
        if (fee > 0) {
            // Treasury must be configured before fees can be collected
            address treasury = getFeeTreasury();
            require(treasury != address(0), ZeroAddressNotAllowed("feeTreasury"));
            // Transfer fee from msg.value to the treasury; reverts if the call fails
            (bool success, ) = treasury.call{value: fee}("");
            require(success, FailedToDeductFee());
        }
    }

    /// @inheritdoc IFluentBridgeRead
    function getSentMessageFee() public view override returns (uint256) {
        // Read fee config from storage once and compute fee inline on the hot send path.
        GasPriceConfig storage gasPriceConfig = _getL2FluentBridgeStorage()._gasPriceConfig;
        uint256 l1GasPrice = IL1GasOracle(getL1GasPriceOracle()).getL1GasPrice();
        uint256 perUnitCost = ((l1GasPrice * gasPriceConfig._scalarGasPrice)) / 1e18 + gasPriceConfig._overheadGasPrice;
        // Total fee = assumed L1 gas units * per-unit cost (scalar-adjusted L1 price + overhead).
        return gasPriceConfig._l1GasLimit * perUnitCost;
    }

    // ============ Receive hooks ============

    /** @inheritdoc FluentBridge
     * @dev Checks if the message has reached its committed expiry block. If so, marks it
     *      Failed and emits {RollbackMessage} (included in L2BlockHeader.withdrawalRoot
     *      for later proof-based rollback on L1). Returns false to skip execution.
     */
    function _beforeReceiveMessage(
        address /* from */,
        address /* to */,
        uint256 value,
        uint256 /* chainId */,
        uint256 validUntilBlockNumber,
        uint256 /* messageNonce */,
        bytes calldata /* message */,
        bytes32 messageHash
    ) internal override returns (bool) {
        // Inbound L1->L2 messages must carry a committed expiry block from L1.
        require(validUntilBlockNumber > 0, ZeroValueNotAllowed("validUntilBlockNumber"));

        // Fetch the latest known L1 block number from the on-chain oracle
        uint256 l1BlockNumber = IL1BlockOracle(getL1BlockOracle()).getL1BlockNumber();

        // If the oracle returns 0, it means the L1 block number is not available yet. In this case, we cannot perform the deadline check.
        require(l1BlockNumber > 0, ZeroValueNotAllowed("l1BlockNumber"));

        // Check whether the message has reached its committed absolute expiry block.
        // The deadline was frozen into the message hash on L1 at send time, so admin
        // updates to the receive-message deadline never retroactively affect this message.
        if (l1BlockNumber >= validUntilBlockNumber) {
            // Mark as Failed so it cannot be executed later
            _getFluentBridgeStorage()._receivedMessage[messageHash] = IFluentBridge.MessageStatus.Failed;
            // RollbackMessage is included in the L2 block's withdrawalRoot,
            // enabling proof-based refund on L1 via rollbackMessageWithProof
            emit RollbackMessage(messageHash, block.number);
            // Return false to skip message execution in the caller
            return false;
        }
        // On Fluent L2, native ETH for inbound messages is minted by the chain's consensus
        // layer before execution and burned if the call fails. The bridge balance is therefore
        // always sufficient by protocol invariant. This check is defense-in-depth — it should
        // never revert under normal operation, but guards against a broken minting mechanism.
        if (value > 0) require(address(this).balance >= value, InsufficientBridgeBalance(value));

        // Committed expiry not reached — allow normal execution to proceed
        return true;
    }

    // ============ Views ============

    /// @inheritdoc IL2FluentBridge
    function getL1BlockOracle() public view returns (address) {
        // Read from ERC-7201 namespaced storage via the storage accessor
        return _getL2FluentBridgeStorage()._l1BlockOracle;
    }

    /**
     * @notice Returns the L1 gas price oracle address.
     */
    function getL1GasPriceOracle() public view returns (address) {
        // Read from ERC-7201 namespaced storage via the storage accessor
        return _getL2FluentBridgeStorage()._l1GasPriceOracle;
    }

    /**
     * @notice Returns the current gas price configuration.
     */
    function getGasPriceConfig() public view returns (GasPriceConfig memory) {
        // Returns a memory copy of the three-field fee config struct
        return _getL2FluentBridgeStorage()._gasPriceConfig;
    }

    /**
     * @notice Returns the assumed L1 gas units used for fee calculation.
     */
    function getL1GasLimit() public view returns (uint256) {
        // Read directly from storage to avoid a full struct memory copy.
        return _getL2FluentBridgeStorage()._gasPriceConfig._l1GasLimit;
    }

    /** @dev Computes the L1 gas cost component of the send fee using oracle price and config. */
    function _calculateGasCost() internal view returns (uint256) {
        // Read config from storage to avoid a full struct memory copy.
        GasPriceConfig storage gasPriceConfig = _getL2FluentBridgeStorage()._gasPriceConfig;
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

    /** @dev Stores the L1 block oracle. Always required — every inbound L1->L2 message
     *       must validate its committed expiry against the L1 block number read from the oracle.
     */
    function _setL1BlockOracle(address l1BlockOracle) internal {
        require(l1BlockOracle != address(0), ZeroAddressNotAllowed("l1BlockOracle"));
        // Emit before writing so event carries both old and new addresses
        emit L1BlockOracleUpdated(getL1BlockOracle(), l1BlockOracle);
        // Persist the new oracle in ERC-7201 namespaced storage
        _getL2FluentBridgeStorage()._l1BlockOracle = l1BlockOracle;
    }

    /**
     * @notice Updates the L1 gas price oracle address.
     */
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

    /**
     * @notice Updates the gas price configuration.
     */
    function setGasPriceConfig(uint256 overheadGasPrice, uint256 scalarGasPrice, uint256 l1GasLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Admin-gated — all three parameters are updated atomically
        _setGasPriceConfig(overheadGasPrice, scalarGasPrice, l1GasLimit);
    }

    /** @dev Stores gas price parameters and emits update event. */
    function _setGasPriceConfig(uint256 overheadGasPrice, uint256 scalarGasPrice, uint256 l1GasLimit) internal {
        // Load storage pointer once to batch writes and emit old values
        GasPriceConfig storage $ = _getL2FluentBridgeStorage()._gasPriceConfig;
        // Emit before writing so the event contains both old and new values
        emit GasPriceConfigUpdated($._overheadGasPrice, overheadGasPrice, $._scalarGasPrice, scalarGasPrice, $._l1GasLimit, l1GasLimit);
        // Update all three fee parameters atomically
        $._overheadGasPrice = overheadGasPrice;
        $._scalarGasPrice = scalarGasPrice;
        $._l1GasLimit = l1GasLimit;
    }
}
