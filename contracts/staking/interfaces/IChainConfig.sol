// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

interface IChainConfigEvents {
    event ActiveValidatorsLengthChanged(uint32 prevValue, uint32 newValue);
    event EpochBlockIntervalChanged(uint32 prevValue, uint32 newValue);
    event MisdemeanorThresholdChanged(uint32 prevValue, uint32 newValue);
    event FelonyThresholdChanged(uint32 prevValue, uint32 newValue);
    event ValidatorJailEpochLengthChanged(uint32 prevValue, uint32 newValue);
    event MissThresholdChanged(uint32 prevValue, uint32 newValue);
    event SlashReporterRewardBpsChanged(uint32 prevValue, uint32 newValue);
    event UndelegatePeriodChanged(uint32 prevValue, uint32 newValue);
    event MinValidatorStakeAmountChanged(uint256 prevValue, uint256 newValue);
    event MinStakingAmountChanged(uint256 prevValue, uint256 newValue);
    event BlsVerifierChanged(address prevValue, address newValue);
    event EvidenceDecoderChanged(address prevValue, address newValue);
    event DposActivationBlockChanged(uint64 prevValue, uint64 newValue);
}

/// @title Staking chain configuration interface
/// @notice Exposes governance-controlled parameters used by validator staking and reward accounting.
interface IChainConfig {
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

    /// @notice DPoS activation block must be a multiple of `epochBlockInterval`
    ///         so absolute and relative epoch boundaries coincide.
    error UnalignedActivationBlock();

    /// @notice DPoS activation block must not be in the past (would jump the
    ///         epoch clock discontinuously and strand the commit cursor).
    error ActivationBlockInPast();

    /// @notice `activeValidatorsLength` must not exceed `MAX_ACTIVE_VALIDATORS`
    ///         — kept lock-step with the consensus peer-set cap
    ///         (`fluentbase_p2p::MAX_PEER_SET_SIZE`) and the `committee_size: u8`
    ///         extra-data wire format. A larger value would desync the on-chain
    ///         committee from the consensus oracle.
    error MaxActiveValidatorsExceeded(uint32 requested, uint32 max);

    /// @notice Epoch-numbering parameters (`epochBlockInterval`,
    ///         `dposActivationBlock`) are immutable once DPoS activation has
    ///         passed — a live change renumbers every epoch, stranding committed
    ///         committees and splitting restart-vs-running nodes.
    error DposAlreadyActive();

    /// @notice The undelegation window (`undelegatePeriod × epochBlockInterval`,
    ///         in blocks) must outlive the equivocation-evidence finality window
    ///         so stake cannot exit before it can be slashed.
    error UndelegateWindowTooShort(uint256 windowBlocks, uint256 minBlocks);

    /// @notice The equivocation reporter reward (basis points) exceeds the cap.
    ///         Capped strictly below 100% so a seizure always burns a deterrent remainder.
    error SlashReporterRewardBpsTooHigh(uint32 requested, uint32 max);

    /// @notice Maximum number of validators returned in the active validator set.
    function getActiveValidatorsLength() external view returns (uint32);

    /// @notice Updates the active validator set size. Callable by governance.
    function setActiveValidatorsLength(uint32 newValue) external;

    /// @notice Number of blocks in one staking epoch.
    function getEpochBlockInterval() external view returns (uint32);

    /// @notice Updates the staking epoch length. Callable by governance.
    function setEpochBlockInterval(uint32 newValue) external;

    /// @notice Block at which DPoS epoch numbering rebases to zero (0 ⇒ absolute).
    function getDposActivationBlock() external view returns (uint64);

    /// @notice Sets the DPoS activation block (aligned, not in the past). Callable by governance.
    function setDposActivationBlock(uint64 newValue) external;

    /// @notice Number of slash events treated as a misdemeanor threshold.
    function getMisdemeanorThreshold() external view returns (uint32);

    /// @notice Updates the misdemeanor slash threshold. Callable by governance.
    function setMisdemeanorThreshold(uint32 newValue) external;

    /// @notice Number of slash events after which a validator is jailed.
    function getFelonyThreshold() external view returns (uint32);

    /// @notice Updates the felony slash threshold. Callable by governance.
    function setFelonyThreshold(uint32 newValue) external;

    /// @notice Number of epochs a jailed validator must wait before release.
    function getValidatorJailEpochLength() external view returns (uint32);

    /// @notice Updates validator jail duration in epochs. Callable by governance.
    function setValidatorJailEpochLength(uint32 newValue) external;

    /// @notice Consecutive missed blocks that dispatch one liveness slash.
    ///         Defaults to 50 when unset (sentinel) so an un-migrated config
    ///         never reads 0 (which would slash on the first absence).
    function getMissThreshold() external view returns (uint32);

    /// @notice Updates the consecutive-miss liveness threshold. Callable by governance.
    function setMissThreshold(uint32 newValue) external;

    /// @notice Reporter's cut (basis points) of an equivocation stake seizure; the
    ///         remainder is burned. Defaults to 3000 (30%) when unset (sentinel).
    function getSlashReporterRewardBps() external view returns (uint32);

    /// @notice Updates the equivocation reporter reward (basis points). Callable by governance.
    function setSlashReporterRewardBps(uint32 newValue) external;

    /// @notice Number of epochs before undelegated funds become claimable.
    function getUndelegatePeriod() external view returns (uint32);

    /// @notice Updates the undelegation delay in epochs. Callable by governance.
    function setUndelegatePeriod(uint32 newValue) external;

    /// @notice Minimum self-stake required to register a validator.
    function getMinValidatorStakeAmount() external view returns (uint256);

    /// @notice Updates validator registration minimum stake. Callable by governance.
    function setMinValidatorStakeAmount(uint256 newValue) external;

    /// @notice Minimum delegation amount accepted by staking.
    function getMinStakingAmount() external view returns (uint256);

    /// @notice Updates minimum delegation amount. Callable by governance.
    function setMinStakingAmount(uint256 newValue) external;

    /// @notice Address of the BLS12-381 MinSig verify contract.
    function getBlsVerifier() external view returns (address);

    /// @notice Updates the BLS verifier address. Callable by governance.
    function setBlsVerifier(address newValue) external;

    /// @notice Address of the Simplex equivocation-evidence decoder contract.
    function getEvidenceDecoder() external view returns (address);

    /// @notice Updates the evidence decoder address. Callable by governance.
    function setEvidenceDecoder(address newValue) external;
}
