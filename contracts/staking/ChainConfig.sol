// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StakingContext} from "./StakingContext.sol";

import {IStaking} from "./interfaces/IStaking.sol";
import {IFluentGovernance} from "./interfaces/IFluentGovernance.sol";
import {IStakingPool} from "./interfaces/IStakingPool.sol";
import {ISystemReward} from "./interfaces/ISystemReward.sol";
import {IChainConfig, IChainConfigEvents} from "./interfaces/IChainConfig.sol";

/**
 * @title Staking chain configuration
 * @author Fluent Labs
 * @notice Stores consensus and staking parameters controlled by governance.
 * @dev Values are consumed by `Staking` and `StakingPool` for epoch, jail, undelegation, and minimum stake logic.
 */
contract ChainConfig is StakingContext, IChainConfig, IChainConfigEvents {
    // ERC-7201 storage namespace:
    // keccak256(abi.encode(uint256(keccak256("Fluent.storage.ChainConfigStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CHAIN_CONFIG_STORAGE_LOCATION = 0x8046150a36ce023dec392c496d6e64fcdc42b4e5054073dafc987cdbcc500e00;

    /// @notice Hard cap on `activeValidatorsLength` (the COMMITTEE size; the
    ///         tier-2 registry fed to the p2p tracker is uncapped here). MUST
    ///         stay byte-equal to `fluentbase_p2p::constants::MAX_COMMITTEE_SIZE`
    ///         (51) and ≤ 255 (the `committee_size: u8` extra-data wire format).
    ///         Raising it requires a coordinated bump on both the contract and
    ///         the Rust consensus side in the same release.
    uint32 public constant MAX_ACTIVE_VALIDATORS = 51;

    /// @notice Default reporter cut (basis points) of an equivocation stake seizure, used
    ///         when the `_slashReporterRewardBps` slot is unset (0). 3000 = 30% reporter,
    ///         70% burned.
    uint32 public constant DEFAULT_SLASH_REPORTER_BPS = 3000;

    /// @notice Upper bound on the reporter cut. Capped strictly below 100% so an
    ///         equivocation seizure always destroys real capital (the burned remainder is
    ///         the economic deterrent). A 100% reporter cut would let a colluding
    ///         self-reporter recover the entire seized self-stake, neutering the penalty.
    uint32 public constant MAX_SLASH_REPORTER_BPS = 5000; // 50%

    /// @notice Default minimum windowed participation (bps of certs seen) below which a
    ///         committee member is eligible for the participation-floor jail; used when the
    ///         `_participationFloorBps` slot is unset (0). 1500 = 15% of certs in the window —
    ///         an extreme-tail floor for Simplex stop-at-quorum (structural mean cert-inclusion
    ///         ~68.6%), so only near-zero non-voters trip it, never a merely-slow honest node.
    uint32 public constant DEFAULT_PARTICIPATION_FLOOR_BPS = 1500;

    /// @notice Hard cap on `participationFloorBps` (20%). Tightened well below the ~68.6%
    ///         structural mean so a governance actor can never set the floor high enough to jail
    ///         the honest latency-distant tail and halt the chain.
    uint32 public constant MAX_PARTICIPATION_FLOOR_BPS = 2000;

    // --- BLEND stipend (PLACEHOLDER — user will tune) ---
    /// @notice Sanity cap on the per-epoch BLEND stipend.
    uint256 public constant MAX_BLEND_STIPEND_PER_EPOCH = 1_000_000 ether;

    // F1 exit-before-slash floor: the undelegation window
    // (undelegatePeriod * epochBlockInterval, in blocks) must be >= this.
    // Immutable (set at implementation deploy) so it cannot be lowered by the
    // governance actor it defends against — only a UUPS upgrade (already the
    // root of trust) can change it. Prod deploy: 345_600 (two times 48h at 1s
    // slots, still >=48h even at 600ms slots); devnet: 0 (guard off).
    uint256 internal immutable _minUndelegateBlocks;

    /// @custom:storage-location erc7201:Fluent.storage.ChainConfigStorage
    struct ChainConfigStorage {
        /**
         * @dev Maximum number of validators returned in the active validator set.
         */
        uint32 _activeValidatorsLength;
        /**
         * @dev Number of blocks in one staking epoch.
         */
        uint32 _epochBlockInterval;
        /**
         * @dev Number of slash events after which a validator is jailed.
         */
        uint32 _felonyThreshold;
        /**
         * @dev Number of epochs a jailed validator must wait before release.
         */
        uint32 _validatorJailEpochLength;
        /**
         * @dev Number of epochs before undelegated funds become claimable.
         */
        uint32 _undelegatePeriod;
        /**
         * @dev Minimum self-stake required to register a validator.
         */
        uint256 _minValidatorStakeAmount;
        /**
         * @dev Minimum staking amount required to delegate to a validator.
         */
        uint256 _minStakingAmount;
        // Appended (ERC-7201 safe): equivocation-slashing crypto units.
        address _blsVerifier;
        address _evidenceDecoder;
        // Appended (ERC-7201 safe): block at which DPoS epoch numbering rebases
        // to zero — `_currentEpoch = (block.number - this) / interval`. Zero ⇒
        // absolute numbering (pre-migration / non-DPoS default).
        uint64 _dposActivationBlock;
        // Appended (ERC-7201 safe): reporter's cut (basis points) of an equivocation
        // stake seizure; the remainder is burned. Zero ⇒ DEFAULT_SLASH_REPORTER_BPS
        // (sentinel; see getSlashReporterRewardBps).
        uint32 _slashReporterRewardBps;
        // Appended (ERC-7201 safe): minimum windowed participation (bps of certs seen) below
        // which a committee member is eligible for the participation-floor jail. Zero ⇒
        // DEFAULT_PARTICIPATION_FLOOR_BPS (sentinel; see getParticipationFloorBps).
        uint32 _participationFloorBps;
        // Appended (ERC-7201 safe): per-epoch BLEND stipend. Zero == OFF (RAW value, NOT a sentinel).
        uint256 _blendStipendPerEpoch;
        // Appended (ERC-7201 safe): destination for the non-reporter remainder of an equivocation
        // stake seizure (damage-coverage fund). address(0) == burn the remainder to the dead
        // address (RAW value, NOT a sentinel; see StakingDpos._seizeSelfStake).
        address _slashFundAddress;
        // Appended (ERC-7201 safe): governance kill switch for the participation-floor jail. When
        // true, LivenessSlashing._finalizeWindow still finalizes windows and accumulates counters
        // but skips the belowFloor scan / jail dispatch entirely. false (fresh slot) == jail
        // enabled == today's behavior (RAW bool, NOT a sentinel; see getParticipationJailDisabled).
        bool _participationJailDisabled;
    }

    function _getChainConfigStorage() private pure returns (ChainConfigStorage storage $) {
        assembly {
            $.slot := CHAIN_CONFIG_STORAGE_LOCATION
        }
    }

    constructor(
        IStaking stakingContract,
        ISystemReward systemRewardContract,
        IStakingPool stakingPoolContract,
        IFluentGovernance governanceContract,
        IChainConfig chainConfigContract,
        IERC20 stakingToken,
        uint256 minUndelegateBlocks
    )
        StakingContext(
            stakingContract,
            systemRewardContract,
            stakingPoolContract,
            governanceContract,
            chainConfigContract,
            stakingToken
        )
    {
        _minUndelegateBlocks = minUndelegateBlocks;
    }

    function initialize(
        address initialOwner,
        uint32 activeValidatorsLength,
        uint32 epochBlockInterval,
        uint32 felonyThreshold,
        uint32 validatorJailEpochLength,
        uint32 undelegatePeriod,
        uint256 minValidatorStakeAmount,
        uint256 minStakingAmount,
        uint64 dposActivationBlock,
        address blsVerifier,
        address evidenceDecoder
    ) external initializer {
        __StakingContext_init(initialOwner);
        __ChainConfig_init(
            activeValidatorsLength,
            epochBlockInterval,
            felonyThreshold,
            validatorJailEpochLength,
            undelegatePeriod,
            minValidatorStakeAmount,
            minStakingAmount,
            dposActivationBlock,
            blsVerifier,
            evidenceDecoder
        );
    }

    function getActiveValidatorsLength() external view override returns (uint32) {
        return _getChainConfigStorage()._activeValidatorsLength;
    }

    function setActiveValidatorsLength(uint32 newValue) external override onlyFromGovernance {
        require(newValue > 0, ZeroValue("activeValidatorsLength"));
        require(newValue <= MAX_ACTIVE_VALIDATORS, MaxActiveValidatorsExceeded(newValue, MAX_ACTIVE_VALIDATORS));
        ChainConfigStorage storage $ = _getChainConfigStorage();
        emit ActiveValidatorsLengthChanged($._activeValidatorsLength, newValue);
        $._activeValidatorsLength = newValue;
    }

    function getEpochBlockInterval() external view override returns (uint32) {
        return _getChainConfigStorage()._epochBlockInterval;
    }

    function setEpochBlockInterval(uint32 newValue) external override onlyFromGovernance {
        require(newValue > 0, ZeroValue("epochBlockInterval"));
        ChainConfigStorage storage $ = _getChainConfigStorage();
        // Epoch numbering is a live function of the interval, so a change after
        // DPoS activation renumbers all of history. Permit it only while
        // activation is still pending (or unset / non-DPoS).
        require(
            $._dposActivationBlock == 0 || block.number < $._dposActivationBlock, DposAlreadyActive()
        );
        // Keep a pending activation aligned to the new interval (the invariant
        // `setDposActivationBlock` enforces in the other direction).
        if ($._dposActivationBlock != 0) {
            require($._dposActivationBlock % newValue == 0, UnalignedActivationBlock());
        }
        // F1: shrinking the interval also shrinks the undelegation window.
        _requireUndelegateWindow($._undelegatePeriod, newValue);
        emit EpochBlockIntervalChanged($._epochBlockInterval, newValue);
        $._epochBlockInterval = newValue;
    }

    function getDposActivationBlock() external view override returns (uint64) {
        return _getChainConfigStorage()._dposActivationBlock;
    }

    function setDposActivationBlock(uint64 newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        // Re-arming activation AFTER it has passed resets `_currentEpoch` to 0,
        // stranding every committed committee and permanently deadlocking the
        // chain (irreversible — `>= block.number` forbids restoring the old
        // value). Permit (re)scheduling only while activation is still pending.
        require(
            $._dposActivationBlock == 0 || block.number < $._dposActivationBlock, DposAlreadyActive()
        );
        // Aligned activation keeps absolute and relative epoch boundaries
        // coincident, so the rebase is a clean re-index (no split epoch).
        require(newValue % $._epochBlockInterval == 0, UnalignedActivationBlock());
        // A past activation would jump `_currentEpoch` discontinuously and
        // strand the committee commit cursor; only forward activation is safe.
        require(newValue >= block.number, ActivationBlockInPast());
        emit DposActivationBlockChanged($._dposActivationBlock, newValue);
        $._dposActivationBlock = newValue;
    }

    function getFelonyThreshold() external view override returns (uint32) {
        return _getChainConfigStorage()._felonyThreshold;
    }

    function setFelonyThreshold(uint32 newValue) external override onlyFromGovernance {
        require(newValue > 0, ZeroValue("felonyThreshold"));
        ChainConfigStorage storage $ = _getChainConfigStorage();
        emit FelonyThresholdChanged($._felonyThreshold, newValue);
        $._felonyThreshold = newValue;
    }

    function getValidatorJailEpochLength() external view override returns (uint32) {
        return _getChainConfigStorage()._validatorJailEpochLength;
    }

    function setValidatorJailEpochLength(uint32 newValue) external override onlyFromGovernance {
        require(newValue > 0, ZeroValue("validatorJailEpochLength"));
        ChainConfigStorage storage $ = _getChainConfigStorage();
        emit ValidatorJailEpochLengthChanged($._validatorJailEpochLength, newValue);
        $._validatorJailEpochLength = newValue;
    }

    function getSlashReporterRewardBps() external view override returns (uint32) {
        uint32 stored = _getChainConfigStorage()._slashReporterRewardBps;
        return stored == 0 ? DEFAULT_SLASH_REPORTER_BPS : stored;
    }

    function setSlashReporterRewardBps(uint32 newValue) external override onlyFromGovernance {
        require(newValue > 0, ZeroValue("slashReporterRewardBps"));
        require(newValue <= MAX_SLASH_REPORTER_BPS, SlashReporterRewardBpsTooHigh(newValue, MAX_SLASH_REPORTER_BPS));
        ChainConfigStorage storage $ = _getChainConfigStorage();
        emit SlashReporterRewardBpsChanged($._slashReporterRewardBps, newValue);
        $._slashReporterRewardBps = newValue;
    }

    /// @dev RAW getter: address(0) == fund unset ⇒ the seizure remainder is burned. NOT a sentinel.
    function getSlashFundAddress() external view override returns (address) {
        return _getChainConfigStorage()._slashFundAddress;
    }

    /// @dev Non-zero only: once a damage-coverage fund is wired, governance rotates it to another
    ///      fund rather than back to burn (the dead-address burn is the genesis default, reachable
    ///      only while the slot is still unset). Mirrors the setBlsVerifier / setEvidenceDecoder idiom.
    function setSlashFundAddress(address newValue) external override onlyFromGovernance {
        require(newValue != address(0), ZeroValue("slashFundAddress"));
        ChainConfigStorage storage $ = _getChainConfigStorage();
        emit SlashFundAddressChanged($._slashFundAddress, newValue);
        $._slashFundAddress = newValue;
    }

    function getParticipationFloorBps() external view override returns (uint32) {
        uint32 stored = _getChainConfigStorage()._participationFloorBps;
        return stored == 0 ? DEFAULT_PARTICIPATION_FLOOR_BPS : stored;
    }

    function setParticipationFloorBps(uint32 newValue) external override onlyFromGovernance {
        require(newValue > 0, ZeroValue("participationFloorBps"));
        require(
            newValue <= MAX_PARTICIPATION_FLOOR_BPS,
            ParticipationFloorBpsTooHigh(newValue, MAX_PARTICIPATION_FLOOR_BPS)
        );
        ChainConfigStorage storage $ = _getChainConfigStorage();
        emit ParticipationFloorBpsChanged($._participationFloorBps, newValue);
        $._participationFloorBps = newValue;
    }

    /// @dev RAW getter: false (fresh slot) == the participation-floor jail is ENABLED (today's
    ///      behavior). true == the jail is disabled: LivenessSlashing keeps finalizing windows and
    ///      accumulating seen/certs counters, but never jails a below-floor member. NOT a sentinel.
    function getParticipationJailDisabled() external view override returns (bool) {
        return _getChainConfigStorage()._participationJailDisabled;
    }

    /// @dev Governance kill switch for the participation-floor jail. Windows finalized while
    ///      disabled are permanently unjudged (the finalize cursor still advances past them), so
    ///      re-enabling does NOT retro-judge the skipped windows — this is the intended interim
    ///      behavior. Counters stay readable via LivenessSlashing.participation() throughout.
    function setParticipationJailDisabled(bool newValue) external override onlyFromGovernance {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        emit ParticipationJailDisabledChanged($._participationJailDisabled, newValue);
        $._participationJailDisabled = newValue;
    }

    /// @dev RAW getter: 0 == the BLEND stipend is OFF (kill-switch). NOT a sentinel default.
    function getBlendStipendPerEpoch() external view override returns (uint256) {
        return _getChainConfigStorage()._blendStipendPerEpoch;
    }

    /// @dev Deviation from the sentinel idiom: 0 is a valid (off) value, so `require(>0)` is
    ///      dropped; the MAX cap + event stay.
    function setBlendStipendPerEpoch(uint256 newValue) external override onlyFromGovernance {
        require(
            newValue <= MAX_BLEND_STIPEND_PER_EPOCH, BlendStipendPerEpochTooHigh(newValue, MAX_BLEND_STIPEND_PER_EPOCH)
        );
        ChainConfigStorage storage $ = _getChainConfigStorage();
        emit BlendStipendPerEpochChanged($._blendStipendPerEpoch, newValue);
        $._blendStipendPerEpoch = newValue;
    }

    function getUndelegatePeriod() external view override returns (uint32) {
        return _getChainConfigStorage()._undelegatePeriod;
    }

    function setUndelegatePeriod(uint32 newValue) external override onlyFromGovernance {
        require(newValue > 0, ZeroValue("undelegatePeriod"));
        ChainConfigStorage storage $ = _getChainConfigStorage();
        // F1: the undelegation window (period × interval, in blocks) must outlive
        // the equivocation-evidence finality window.
        _requireUndelegateWindow(newValue, $._epochBlockInterval);
        emit UndelegatePeriodChanged($._undelegatePeriod, newValue);
        $._undelegatePeriod = newValue;
    }

    /// @dev F1 floor check shared by both setters and `initialize`.
    /// @dev F1 floor check. Widens to uint256 internally so callers never have to
    ///      remember the cast (a missing one would compute the window in checked
    ///      uint32 and revert with a spurious overflow on a large-but-valid config).
    function _requireUndelegateWindow(uint32 period, uint32 interval) private view {
        uint256 windowBlocks = uint256(period) * interval;
        require(windowBlocks >= _minUndelegateBlocks, UndelegateWindowTooShort(windowBlocks, _minUndelegateBlocks));
    }

    function getMinValidatorStakeAmount() external view returns (uint256) {
        return _getChainConfigStorage()._minValidatorStakeAmount;
    }

    function setMinValidatorStakeAmount(uint256 newValue) external override onlyFromGovernance {
        require(newValue > 0, ZeroValue("minValidatorStakeAmount"));
        ChainConfigStorage storage $ = _getChainConfigStorage();
        emit MinValidatorStakeAmountChanged($._minValidatorStakeAmount, newValue);
        $._minValidatorStakeAmount = newValue;
    }

    function getMinStakingAmount() external view returns (uint256) {
        return _getChainConfigStorage()._minStakingAmount;
    }

    function setMinStakingAmount(uint256 newValue) external override onlyFromGovernance {
        require(newValue > 0, ZeroValue("minStakingAmount"));
        ChainConfigStorage storage $ = _getChainConfigStorage();
        emit MinStakingAmountChanged($._minStakingAmount, newValue);
        $._minStakingAmount = newValue;
    }

    function __ChainConfig_init(
        uint32 activeValidatorsLength,
        uint32 epochBlockInterval,
        uint32 felonyThreshold,
        uint32 validatorJailEpochLength,
        uint32 undelegatePeriod,
        uint256 minValidatorStakeAmount,
        uint256 minStakingAmount,
        uint64 dposActivationBlock,
        address blsVerifier,
        address evidenceDecoder
    ) internal onlyInitializing {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        require(activeValidatorsLength > 0, ZeroValue("activeValidatorsLength"));
        require(
            activeValidatorsLength <= MAX_ACTIVE_VALIDATORS,
            MaxActiveValidatorsExceeded(activeValidatorsLength, MAX_ACTIVE_VALIDATORS)
        );
        $._activeValidatorsLength = activeValidatorsLength;
        emit ActiveValidatorsLengthChanged(0, activeValidatorsLength);

        require(epochBlockInterval > 0, ZeroValue("epochBlockInterval"));
        $._epochBlockInterval = epochBlockInterval;
        emit EpochBlockIntervalChanged(0, epochBlockInterval);

        require(felonyThreshold > 0, ZeroValue("felonyThreshold"));
        $._felonyThreshold = felonyThreshold;
        emit FelonyThresholdChanged(0, felonyThreshold);

        require(validatorJailEpochLength > 0, ZeroValue("validatorJailEpochLength"));
        $._validatorJailEpochLength = validatorJailEpochLength;
        emit ValidatorJailEpochLengthChanged(0, validatorJailEpochLength);

        require(undelegatePeriod > 0, ZeroValue("undelegatePeriod"));
        // F1: window (period × interval) must clear the immutable floor at init.
        _requireUndelegateWindow(undelegatePeriod, epochBlockInterval);
        $._undelegatePeriod = undelegatePeriod;
        emit UndelegatePeriodChanged(0, undelegatePeriod);

        require(minValidatorStakeAmount > 0, ZeroValue("minValidatorStakeAmount"));
        $._minValidatorStakeAmount = minValidatorStakeAmount;
        emit MinValidatorStakeAmountChanged(0, minValidatorStakeAmount);

        require(minStakingAmount > 0, ZeroValue("minStakingAmount"));
        $._minStakingAmount = minStakingAmount;
        emit MinStakingAmountChanged(0, minStakingAmount);

        require(dposActivationBlock % epochBlockInterval == 0, UnalignedActivationBlock());
        $._dposActivationBlock = dposActivationBlock;
        emit DposActivationBlockChanged(0, dposActivationBlock);

        // Seed the equivocation-slashing crypto units at genesis so slashing is live on a
        // fresh deploy. They are otherwise only settable post-deploy via `setBlsVerifier` /
        // `setEvidenceDecoder`, which are `onlyFromGovernance` and so cannot run inside a
        // deploy broadcast. address(0) ⇒ left unset (slashing stays disabled — the
        // NotConfigured guards in StakingDpos revert — until governance wires it); governance
        // can still rotate either unit later.
        if (blsVerifier != address(0)) {
            $._blsVerifier = blsVerifier;
            emit BlsVerifierChanged(address(0), blsVerifier);
        }
        if (evidenceDecoder != address(0)) {
            $._evidenceDecoder = evidenceDecoder;
            emit EvidenceDecoderChanged(address(0), evidenceDecoder);
        }
    }

    function getBlsVerifier() external view override returns (address) {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        return $._blsVerifier;
    }

    function setBlsVerifier(address newValue) external override onlyFromGovernance {
        require(newValue != address(0), ZeroValue("blsVerifier"));
        ChainConfigStorage storage $ = _getChainConfigStorage();
        address prevValue = $._blsVerifier;
        $._blsVerifier = newValue;
        emit BlsVerifierChanged(prevValue, newValue);
    }

    function getEvidenceDecoder() external view override returns (address) {
        ChainConfigStorage storage $ = _getChainConfigStorage();
        return $._evidenceDecoder;
    }

    function setEvidenceDecoder(address newValue) external override onlyFromGovernance {
        require(newValue != address(0), ZeroValue("evidenceDecoder"));
        ChainConfigStorage storage $ = _getChainConfigStorage();
        address prevValue = $._evidenceDecoder;
        $._evidenceDecoder = newValue;
        emit EvidenceDecoderChanged(prevValue, newValue);
    }
}
