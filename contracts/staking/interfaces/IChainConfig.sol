// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/**
 * @title IChainConfigEvents
 * @author Fluent Labs
 * @notice Events emitted by {ChainConfig} whenever a governance-managed parameter is updated.
 */
interface IChainConfigEvents {
    /**
     * @notice Emitted when the active validator set size is updated.
     */
    event ActiveValidatorsLengthChanged(uint32 prevValue, uint32 newValue);

    /**
     * @notice Emitted when the epoch length (in blocks) is updated.
     */
    event EpochBlockIntervalChanged(uint32 prevValue, uint32 newValue);

    /**
     * @notice Emitted when the misdemeanor slash threshold is updated.
     */
    event MisdemeanorThresholdChanged(uint32 prevValue, uint32 newValue);

    /**
     * @notice Emitted when the felony slash threshold is updated.
     */
    event FelonyThresholdChanged(uint32 prevValue, uint32 newValue);

    /**
     * @notice Emitted when the validator jail duration (in epochs) is updated.
     */
    event ValidatorJailEpochLengthChanged(uint32 prevValue, uint32 newValue);

    /**
     * @notice Emitted when the undelegation delay (in epochs) is updated.
     */
    event UndelegatePeriodChanged(uint32 prevValue, uint32 newValue);

    /**
     * @notice Emitted when the minimum validator self-stake is updated.
     */
    event MinValidatorStakeAmountChanged(uint256 prevValue, uint256 newValue);

    /**
     * @notice Emitted when the minimum delegation amount is updated.
     */
    event MinStakingAmountChanged(uint256 prevValue, uint256 newValue);
}

/**
 * @title IChainConfig
 * @author Fluent Labs
 * @notice Governance-controlled chain-level parameters used by validator staking and reward accounting.
 * @dev All setters are gated to the configured governance contract; values default to those passed
 *      in at initialization and can later be tuned through governance proposals.
 */
interface IChainConfig is IChainConfigEvents {
    // ============ Errors ============

    /**
     * @notice Value must be strictly greater than zero.
     * @param field Name of the rejected configuration field, included for off-chain diagnostics.
     */
    error ZeroValue(string field);

    /**
     * @notice Slash threshold ordering invariant was violated.
     * @dev Misdemeanor threshold must be `<=` felony threshold (and felony must be `>=`
     *      misdemeanor) so escalation always progresses; raised by either setter when the new
     *      value would invert the ordering, and by initialization when the bootstrap parameters
     *      are inconsistent.
     */
    error MisdemeanorThresholdNotMet();

    // ============ Active validator set ============

    /**
     * @notice Returns the maximum number of validators included in the active validator set.
     * @return value Active validator set size.
     */
    function getActiveValidatorsLength() external view returns (uint32 value);

    /**
     * @notice Updates the active validator set size.
     * @dev Callable only by governance.
     * @param newValue New active validator set size (must be > 0).
     */
    function setActiveValidatorsLength(uint32 newValue) external;

    // ============ Epoch length ============

    /**
     * @notice Returns the number of blocks in one staking epoch.
     * @return value Epoch length in blocks.
     */
    function getEpochBlockInterval() external view returns (uint32 value);

    /**
     * @notice Updates the staking epoch length.
     * @dev Callable only by governance.
     * @param newValue New epoch length in blocks (must be > 0).
     */
    function setEpochBlockInterval(uint32 newValue) external;

    // ============ Slashing thresholds ============

    /**
     * @notice Returns the number of slash events that constitutes the misdemeanor threshold.
     * @return value Misdemeanor threshold.
     */
    function getMisdemeanorThreshold() external view returns (uint32 value);

    /**
     * @notice Updates the misdemeanor slash threshold.
     * @dev Callable only by governance. Reverts if the new value exceeds the felony threshold.
     * @param newValue New misdemeanor threshold (must be > 0 and `<=` felony threshold).
     */
    function setMisdemeanorThreshold(uint32 newValue) external;

    /**
     * @notice Returns the number of slash events at which a validator is jailed.
     * @return value Felony threshold.
     */
    function getFelonyThreshold() external view returns (uint32 value);

    /**
     * @notice Updates the felony slash threshold.
     * @dev Callable only by governance. Reverts if the new value is below the misdemeanor threshold.
     * @param newValue New felony threshold (must be > 0 and `>=` misdemeanor threshold).
     */
    function setFelonyThreshold(uint32 newValue) external;

    // ============ Validator jail ============

    /**
     * @notice Returns the number of epochs a jailed validator must wait before release.
     * @return value Jail duration in epochs.
     */
    function getValidatorJailEpochLength() external view returns (uint32 value);

    /**
     * @notice Updates the validator jail duration in epochs.
     * @dev Callable only by governance.
     * @param newValue New jail duration (must be > 0).
     */
    function setValidatorJailEpochLength(uint32 newValue) external;

    // ============ Undelegation ============

    /**
     * @notice Returns the number of epochs an undelegated amount must wait before it becomes claimable.
     * @return value Undelegation delay in epochs.
     */
    function getUndelegatePeriod() external view returns (uint32 value);

    /**
     * @notice Updates the undelegation delay.
     * @dev Callable only by governance.
     * @param newValue New undelegation delay (must be > 0).
     */
    function setUndelegatePeriod(uint32 newValue) external;

    // ============ Minimum stake amounts ============

    /**
     * @notice Returns the minimum self-stake required to register a validator.
     * @return value Minimum validator self-stake.
     */
    function getMinValidatorStakeAmount() external view returns (uint256 value);

    /**
     * @notice Updates the minimum validator self-stake.
     * @dev Callable only by governance.
     * @param newValue New minimum validator self-stake (must be > 0).
     */
    function setMinValidatorStakeAmount(uint256 newValue) external;

    /**
     * @notice Returns the minimum delegation amount accepted by staking.
     * @return value Minimum delegation amount.
     */
    function getMinStakingAmount() external view returns (uint256 value);

    /**
     * @notice Updates the minimum delegation amount.
     * @dev Callable only by governance.
     * @param newValue New minimum delegation amount (must be > 0).
     */
    function setMinStakingAmount(uint256 newValue) external;
}
