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

    /// @notice Hard cap on `activeValidatorsLength`. MUST stay byte-equal to
    ///         `fluentbase_p2p::constants::MAX_PEER_SET_SIZE` (51) and ≤ 255
    ///         (the `committee_size: u8` extra-data wire format). Raising it
    ///         requires a coordinated bump on both the contract and the Rust
    ///         consensus side in the same release.
    uint32 public constant MAX_ACTIVE_VALIDATORS = 51;

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
         * @dev Number of slash events treated as a misdemeanor threshold.
         */
        uint32 _misdemeanorThreshold;
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
        uint32 misdemeanorThreshold,
        uint32 felonyThreshold,
        uint32 validatorJailEpochLength,
        uint32 undelegatePeriod,
        uint256 minValidatorStakeAmount,
        uint256 minStakingAmount,
        uint64 dposActivationBlock
    ) external initializer {
        __StakingContext_init(initialOwner);
        __ChainConfig_init(
            activeValidatorsLength,
            epochBlockInterval,
            misdemeanorThreshold,
            felonyThreshold,
            validatorJailEpochLength,
            undelegatePeriod,
            minValidatorStakeAmount,
            minStakingAmount,
            dposActivationBlock
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

    function getMisdemeanorThreshold() external view override returns (uint32) {
        return _getChainConfigStorage()._misdemeanorThreshold;
    }

    function setMisdemeanorThreshold(uint32 newValue) external override onlyFromGovernance {
        require(newValue > 0, ZeroValue("misdemeanorThreshold"));
        ChainConfigStorage storage $ = _getChainConfigStorage();
        require(newValue <= $._felonyThreshold, MisdemeanorThresholdNotMet());
        emit MisdemeanorThresholdChanged($._misdemeanorThreshold, newValue);
        $._misdemeanorThreshold = newValue;
    }

    function getFelonyThreshold() external view override returns (uint32) {
        return _getChainConfigStorage()._felonyThreshold;
    }

    function setFelonyThreshold(uint32 newValue) external override onlyFromGovernance {
        require(newValue > 0, ZeroValue("felonyThreshold"));
        ChainConfigStorage storage $ = _getChainConfigStorage();
        require(newValue >= $._misdemeanorThreshold, MisdemeanorThresholdNotMet());
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
        uint32 misdemeanorThreshold,
        uint32 felonyThreshold,
        uint32 validatorJailEpochLength,
        uint32 undelegatePeriod,
        uint256 minValidatorStakeAmount,
        uint256 minStakingAmount,
        uint64 dposActivationBlock
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

        require(misdemeanorThreshold > 0, ZeroValue("misdemeanorThreshold"));
        $._misdemeanorThreshold = misdemeanorThreshold;
        emit MisdemeanorThresholdChanged(0, misdemeanorThreshold);

        require(felonyThreshold > 0, ZeroValue("felonyThreshold"));
        require(felonyThreshold >= misdemeanorThreshold, MisdemeanorThresholdNotMet());
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
