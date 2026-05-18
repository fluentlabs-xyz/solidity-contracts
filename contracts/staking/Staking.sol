// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStaking, IStakingEvents, IStakingErrors} from "./interfaces/IStaking.sol";
import {ISlashingIndicator} from "./interfaces/ISlashingIndicator.sol";
import {ISystemReward} from "./interfaces/ISystemReward.sol";
import {IStakingPool} from "./interfaces/IStakingPool.sol";
import {IFluentGovernance} from "./interfaces/IFluentGovernance.sol";
import {IChainConfig} from "./interfaces/IChainConfig.sol";
import {StakingContext} from "./StakingContext.sol";
import {IBLS12381Verifier} from "./interfaces/IBLS12381Verifier.sol";
import {SimplexEvidenceDecoder} from "../libraries/SimplexEvidenceDecoder.sol";

/**
 * @title Validator staking
 * @author Fluent Labs
 * @notice Manages validator registration, delegation, undelegation, commission, reward claims, active set ordering, and slashing.
 * @dev Uses epoch snapshots and compacted balances to preserve historical accounting without storing full uint256 stake values.
 */
contract Staking is IStaking, StakingContext {
    using SafeERC20 for IERC20;

    // ERC-7201 storage namespace for consensus keys (separate from StakingStorage):
    // keccak256(abi.encode(uint256(keccak256("Fluent.storage.ConsensusKeysStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONSENSUS_KEYS_STORAGE_LOCATION =
        0xf295d610a4116363064013aa5e1168427c6b907b208d8be559665c0e7adec500;

    // ERC-7201 storage namespace for per-epoch frozen committee (separate from StakingStorage/ConsensusKeysStorage):
    // keccak256(abi.encode(uint256(keccak256("Fluent.storage.EpochCommitteeStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EPOCH_COMMITTEE_STORAGE_LOCATION =
        0x8f1c49778ec45f03e87f0e3e1567785ab335a882d8dad6d5c44cb7ae50968400;

    // ERC-7201 storage namespace for equivocation tombstones (separate from all of the above):
    // keccak256(abi.encode(uint256(keccak256("Fluent.storage.EquivocationStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EQUIVOCATION_STORAGE_LOCATION =
        0x96610efdc8a37de390ea3757bf0331faa3a74708adc53f30ba708302b0f55800;

    /// @notice BLS signature DST (MinSig MESSAGE) — distinct from PoP's DST.
    bytes private constant BLS_SIG_DST = "BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_POP_";

    /// @notice BLS PoP DST (MinSig PROOF_OF_POSSESSION) — distinct from BLS_SIG_DST.
    bytes private constant BLS_POP_DST = "BLS_POP_BLS12381G1_XMD:SHA-256_SSWU_RO_POP_";

    /// @notice Expected length of a compressed BLS12-381 G2 pubkey (MinSig variant).
    uint256 internal constant BLS_PUBKEY_LENGTH = 96;

    /// @notice Safety margin (in epochs) added to the undelegate period when
    ///         retaining frozen committees, covering Simplex consensus
    ///         evidence activity_timeout. Exact value = economics calibration
    ///         pre-mainnet.
    uint64 internal constant EPOCH_COMMITTEE_RETENTION_MARGIN = 8;

    /**
     * This constant indicates precision of storing compact balances in the storage or floating point. Since default
     * balance precision is 256 bits it might gain some overhead on the storage because we don't need to store such huge
     * amount range. That is why we compact balances in uint112 values instead of uint256. By managing this value
     * you can set the precision of your balances, aka min and max possible staking amount. This value depends
     * mostly on your asset price in USD, for example ETH costs 4000$ then if we use 1 ether precision it takes 4000$
     * as min amount that might be problematic for users to do the stake. We can set 1 gwei precision and in this case
     * we increase min staking amount in 1e9 times, but also decreases max staking amount or total amount of staked assets.
     *
     * Here is an universal formula, if your asset is cheap in USD equivalent, like ~1$, then use 1 ether precision,
     * otherwise it might be better to use 1 gwei precision or any other amount that your want.
     *
     * Also be careful with setting `minValidatorStakeAmount` and `minStakingAmount`, because these values has
     * the same precision as specified here. It means that if you set precision 1 ether, then min staking amount of 10
     * tokens should have 10 raw value. For 1 gwei precision 10 tokens min amount should be stored as 10000000000.
     *
     * For the 112 bits we have ~32 decimals lg(2**112)=33.71 (lets round to 32 for simplicity). We split this amount
     * into integer (24) and for fractional (8) parts. It means that we can have only 8 decimals after zero.
     *
     * Based in current params we have next min/max values:
     * - min staking amount: 0.00000001 or 1e-8
     * - max staking amount: 1000000000000000000000000 or 1e+24
     *
     * WARNING: precision must be a 1eN format (A=1, N>0)
     */
    uint256 internal constant BALANCE_COMPACT_PRECISION = 1e10;
    /**
     * Here is min/max commission rates. Lets don't allow to set more than 30% of validator commission, because it's
     * too big commission for validator. Commission rate is a percents divided by 100 stored with 0 decimals as percents*100 (=pc/1e2*1e4)
     *
     * Here is some examples:
     * + 0.3% => 0.3*100=30
     * + 3% => 3*100=300
     * + 30% => 30*100=3000
     */
    uint16 internal constant COMMISSION_RATE_MIN_VALUE = 0; // 0%
    uint16 internal constant COMMISSION_RATE_MAX_VALUE = 3000; // 30%
    /**
     * This gas limit is used for internal transfers to contracts that may execute expensive
     * fallback logic, such as transparent or beacon proxies with multiple SLOAD instructions.
     */
    uint64 internal constant TRANSFER_GAS_LIMIT = 30000;

    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.StakingStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STAKING_STORAGE_LOCATION = 0x4102a9ba7244b40639ebe412c7bfc792b19c048efdf631bf4f130fef80c0df00;

    /// @custom:storage-location erc7201:Fluent.storage.StakingStorage
    struct StakingStorage {
        // mapping from validator address to validator
        mapping(address => Validator) _validatorsMap;
        // mapping from validator owner to validator address
        mapping(address => address) _validatorOwners;
        // list of all validators that are in validators mapping
        address[] _activeValidatorsList;
        // mapping with stakers to validators at epoch (validator -> delegator -> delegation)
        mapping(address => mapping(address => ValidatorDelegation)) _validatorDelegations;
        // mapping with validator snapshots per each epoch (validator -> epoch -> snapshot)
        mapping(address => mapping(uint64 => ValidatorSnapshot)) _validatorSnapshots;
    }

    function _getStakingStorage() private pure returns (StakingStorage storage $) {
        assembly {
            $.slot := STAKING_STORAGE_LOCATION
        }
    }

    /// @custom:storage-location erc7201:Fluent.storage.ConsensusKeysStorage
    struct ConsensusKeysStorage {
        mapping(address => IStaking.ConsensusKeys) consensusKeys;
    }

    function _getConsensusKeysStorage() private pure returns (ConsensusKeysStorage storage $) {
        assembly {
            $.slot := CONSENSUS_KEYS_STORAGE_LOCATION
        }
    }

    /// @custom:storage-location erc7201:Fluent.storage.EpochCommitteeStorage
    struct EpochCommitteeStorage {
        // epoch => committee addresses in canonical Simplex committee order
        // (ed25519 peerPubkey ascending, keyless validators excluded).
        // Empty array == that epoch was never committed (=> unslashable, by design).
        mapping(uint64 => address[]) committee;
        // Highest committed epoch, stored as (epoch + 1). 0 == never committed
        // (genesis-safe idempotent + strictly-monotonic guard).
        uint64 lastCommittedEpochP1;
        // Highest pruned epoch, stored as (epoch + 1). Cursor so a bounded
        // range is pruned each commit even when commits skip epochs.
        uint64 prunedUpToP1;
    }

    function _getEpochCommitteeStorage() private pure returns (EpochCommitteeStorage storage $) {
        assembly {
            $.slot := EPOCH_COMMITTEE_STORAGE_LOCATION
        }
    }

    /// @custom:storage-location erc7201:Fluent.storage.EquivocationStorage
    struct EquivocationStorage {
        // validator => permanently slashed for a cryptographic equivocation.
        // The flag IS the replay guard: one-and-done tombstone.
        mapping(address => bool) tombstoned;
    }

    function _getEquivocationStorage() private pure returns (EquivocationStorage storage $) {
        assembly {
            $.slot := EQUIVOCATION_STORAGE_LOCATION
        }
    }

    constructor(
        IStaking stakingContract,
        ISlashingIndicator slashingIndicatorContract,
        ISystemReward systemRewardContract,
        IStakingPool stakingPoolContract,
        IFluentGovernance governanceContract,
        IChainConfig chainConfigContract,
        IERC20 stakingToken
    )
        StakingContext(
            stakingContract,
            slashingIndicatorContract,
            systemRewardContract,
            stakingPoolContract,
            governanceContract,
            chainConfigContract,
            stakingToken
        )
    {}

    /**
     * @param initialOwner The address of the initial owner of the staking contract.
     * @param validators The addresses of initial validators to be added to the staking contract.
     * @param initialStakes The initial stakes of the validators.
     * @param commissionRate The commission rate of the validators.
     */
    function initialize(
        address initialOwner,
        address[] calldata validators,
        uint256[] calldata initialStakes,
        uint16 commissionRate
    ) external initializer {
        __StakingContext_init(initialOwner);
        uint256 numValidators = validators.length;
        require(initialStakes.length == numValidators, MalformedInputLength());
        uint256 totalStakes = 0;
        for (uint256 i = 0; i < numValidators; ) {
            _addValidator(validators[i], validators[i], ValidatorStatus.Active, commissionRate, initialStakes[i], 0);
            totalStakes += initialStakes[i];
            unchecked {
                ++i;
            }
        }

        /// transfer stToken to the contract
        if (totalStakes > 0) _stakingToken.safeTransferFrom(msg.sender, address(this), totalStakes);
    }

    // @inheritdoc IStaking
    function getValidatorDelegation(
        address validatorAddress,
        address delegator
    ) external view override returns (uint256 delegatedAmount, uint64 atEpoch) {
        StakingStorage storage $ = _getStakingStorage();
        ValidatorDelegation memory delegation = $._validatorDelegations[validatorAddress][delegator];
        if (delegation.delegateQueue.length == 0) {
            return (delegatedAmount = 0, atEpoch = 0);
        }
        DelegationOpDelegate memory snapshot = delegation.delegateQueue[delegation.delegateQueue.length - 1];
        return (delegatedAmount = uint256(snapshot.amount) * BALANCE_COMPACT_PRECISION, atEpoch = snapshot.epoch);
    }

    /// @inheritdoc IStaking
    function getValidatorStatus(
        address validatorAddress
    )
        external
        view
        override
        returns (
            address ownerAddress,
            uint8 status,
            uint256 totalDelegated,
            uint32 slashesCount,
            uint64 changedAt,
            uint64 jailedBefore,
            uint64 claimedAt,
            uint16 commissionRate,
            uint96 totalRewards
        )
    {
        StakingStorage storage $ = _getStakingStorage();
        Validator memory validator = $._validatorsMap[validatorAddress];
        ValidatorSnapshot memory snapshot = $._validatorSnapshots[validator.validatorAddress][validator.changedAt];
        return (
            ownerAddress = validator.ownerAddress,
            status = uint8(validator.status),
            totalDelegated = uint256(snapshot.totalDelegated) * BALANCE_COMPACT_PRECISION,
            slashesCount = snapshot.slashesCount,
            changedAt = validator.changedAt,
            jailedBefore = validator.jailedBefore,
            claimedAt = validator.claimedAt,
            commissionRate = snapshot.commissionRate,
            totalRewards = snapshot.totalRewards
        );
    }

    /// @inheritdoc IStaking
    function getValidatorStatusAtEpoch(
        address validatorAddress,
        uint64 epoch
    )
        external
        view
        returns (
            address ownerAddress,
            uint8 status,
            uint256 totalDelegated,
            uint32 slashesCount,
            uint64 changedAt,
            uint64 jailedBefore,
            uint64 claimedAt,
            uint16 commissionRate,
            uint96 totalRewards
        )
    {
        StakingStorage storage $ = _getStakingStorage();
        Validator memory validator = $._validatorsMap[validatorAddress];
        ValidatorSnapshot memory snapshot = _touchValidatorSnapshotImmutable(validator, epoch);
        return (
            ownerAddress = validator.ownerAddress,
            status = uint8(validator.status),
            totalDelegated = uint256(snapshot.totalDelegated) * BALANCE_COMPACT_PRECISION,
            slashesCount = snapshot.slashesCount,
            changedAt = validator.changedAt,
            jailedBefore = validator.jailedBefore,
            claimedAt = validator.claimedAt,
            commissionRate = snapshot.commissionRate,
            totalRewards = snapshot.totalRewards
        );
    }

    /// @inheritdoc IStaking
    function getValidatorByOwner(address owner) external view override returns (address) {
        return _getStakingStorage()._validatorOwners[owner];
    }

    /// @inheritdoc IStaking
    function releaseValidatorFromJail(address validatorAddress) external {
        if (_getEquivocationStorage().tombstoned[validatorAddress]) {
            revert AlreadySlashedForEquivocation(validatorAddress);
        }
        StakingStorage storage $ = _getStakingStorage();
        // make sure validator is in jail
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status == ValidatorStatus.Jail, ValidatorNotInJail(validatorAddress));
        // only validator owner
        require(msg.sender == validator.ownerAddress, OnlyValidatorOwner(validator.ownerAddress));
        require(_currentEpoch() >= validator.jailedBefore, StillInJail(validatorAddress));
        // update validator status
        validator.status = ValidatorStatus.Active;
        $._validatorsMap[validatorAddress] = validator;
        $._activeValidatorsList.push(validatorAddress);
        // emit event
        emit ValidatorReleased(validatorAddress, _currentEpoch());
    }

    function _totalDelegatedToValidator(Validator memory validator) internal view returns (uint256) {
        StakingStorage storage $ = _getStakingStorage();
        ValidatorSnapshot memory snapshot = _validatorSnapshotAtOrBefore($, validator, _currentEpoch());
        return uint256(snapshot.totalDelegated) * BALANCE_COMPACT_PRECISION;
    }

    function _validatorSnapshotAtOrBefore(
        StakingStorage storage $,
        Validator memory validator,
        uint64 epoch
    ) internal view returns (ValidatorSnapshot memory) {
        uint64 lookupEpoch = epoch < validator.changedAt ? epoch : validator.changedAt;
        while (lookupEpoch > 0) {
            ValidatorSnapshot memory snapshot = $._validatorSnapshots[validator.validatorAddress][lookupEpoch];
            if (snapshot.totalDelegated > 0 || snapshot.totalRewards > 0 || snapshot.commissionRate > 0 || snapshot.slashesCount > 0) {
                return snapshot;
            }
            unchecked {
                --lookupEpoch;
            }
        }
        return $._validatorSnapshots[validator.validatorAddress][0];
    }

    function delegate(address validatorAddress, uint256 amount) external override {
        _delegateTo(msg.sender, validatorAddress, amount, true);
    }

    function undelegate(address validatorAddress, uint256 amount) external override {
        _undelegateFrom(msg.sender, validatorAddress, amount);
    }

    function currentEpoch() external view returns (uint64) {
        return _currentEpoch();
    }

    function nextEpoch() external view returns (uint64) {
        return _nextEpoch();
    }

    function _currentEpoch() internal view returns (uint64) {
        return uint64(block.number / _chainConfigContract.getEpochBlockInterval() + 0);
    }

    function _nextEpoch() internal view returns (uint64) {
        return _currentEpoch() + 1;
    }

    function _touchValidatorSnapshot(Validator memory validator, uint64 epoch) internal returns (ValidatorSnapshot storage) {
        StakingStorage storage $ = _getStakingStorage();
        ValidatorSnapshot storage snapshot = $._validatorSnapshots[validator.validatorAddress][epoch];
        // if snapshot is already initialized then just return it
        if (snapshot.totalDelegated > 0) {
            return snapshot;
        }
        // find previous snapshot to copy parameters from it
        ValidatorSnapshot memory lastModifiedSnapshot = $._validatorSnapshots[validator.validatorAddress][validator.changedAt];
        // last modified snapshot might store zero value, for first delegation it might happen and its not critical
        snapshot.totalDelegated = lastModifiedSnapshot.totalDelegated;
        snapshot.commissionRate = lastModifiedSnapshot.commissionRate;
        // we must save last affected epoch for this validator to be able to restore total delegated
        // amount in the future (check condition upper)
        if (epoch > validator.changedAt) {
            validator.changedAt = epoch;
        }
        return snapshot;
    }

    function _touchValidatorSnapshotImmutable(Validator memory validator, uint64 epoch) internal view returns (ValidatorSnapshot memory) {
        StakingStorage storage $ = _getStakingStorage();
        ValidatorSnapshot memory snapshot = $._validatorSnapshots[validator.validatorAddress][epoch];
        // if snapshot is already initialized then just return it
        if (snapshot.totalDelegated > 0) {
            return snapshot;
        }
        // find previous snapshot to copy parameters from it
        ValidatorSnapshot memory lastModifiedSnapshot = $._validatorSnapshots[validator.validatorAddress][validator.changedAt];
        // last modified snapshot might store zero value, for first delegation it might happen and its not critical
        snapshot.totalDelegated = lastModifiedSnapshot.totalDelegated;
        snapshot.commissionRate = lastModifiedSnapshot.commissionRate;
        // return existing or new snapshot
        return snapshot;
    }

    function _delegateTo(address fromDelegator, address toValidator, uint256 amount, bool pullTokens) internal {
        StakingStorage storage $ = _getStakingStorage();
        // check is minimum delegate amount
        require(amount >= _chainConfigContract.getMinStakingAmount() && amount > 0, AmountTooLow(amount));
        require(amount % BALANCE_COMPACT_PRECISION == 0, WrongAmountPrecision());
        if (pullTokens) {
            _stakingToken.safeTransferFrom(fromDelegator, address(this), amount);
        }
        // make sure amount is greater than min staking amount
        // make sure validator exists at least
        Validator memory validator = $._validatorsMap[toValidator];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(toValidator));
        uint64 atEpoch = _nextEpoch();
        // Lets upgrade next snapshot parameters:
        // + find snapshot for the next epoch after current block
        // + increase total delegated amount in the next epoch for this validator
        // + re-save validator because last affected epoch might change
        ValidatorSnapshot storage validatorSnapshot = _touchValidatorSnapshot(validator, atEpoch);
        validatorSnapshot.totalDelegated += uint112(amount / BALANCE_COMPACT_PRECISION);
        $._validatorsMap[toValidator] = validator;
        // if last pending delegate has the same next epoch then its safe to just increase total
        // staked amount because it can't affect current validator set, but otherwise we must create
        // new record in delegation queue with the last epoch (delegations are ordered by epoch)
        ValidatorDelegation storage delegation = $._validatorDelegations[toValidator][fromDelegator];
        if (delegation.delegateQueue.length > 0) {
            DelegationOpDelegate storage recentDelegateOp = delegation.delegateQueue[delegation.delegateQueue.length - 1];
            // if we already have pending snapshot for the next epoch then just increase new amount,
            // otherwise create next pending snapshot. (tbh it can't be greater, but what we can do here instead?)
            if (recentDelegateOp.epoch >= atEpoch) {
                recentDelegateOp.amount += uint112(amount / BALANCE_COMPACT_PRECISION);
            } else {
                delegation.delegateQueue.push(
                    DelegationOpDelegate({epoch: atEpoch, amount: recentDelegateOp.amount + uint112(amount / BALANCE_COMPACT_PRECISION)})
                );
            }
        } else {
            // there is no any delegations at al, lets create the first one
            delegation.delegateQueue.push(DelegationOpDelegate({epoch: atEpoch, amount: uint112(amount / BALANCE_COMPACT_PRECISION)}));
        }
        // emit event with the next epoch
        emit Delegated(toValidator, fromDelegator, amount, atEpoch);
    }

    function _undelegateFrom(address toDelegator, address fromValidator, uint256 amount) internal {
        StakingStorage storage $ = _getStakingStorage();
        // check minimum delegate amount
        require(amount >= _chainConfigContract.getMinStakingAmount() && amount > 0, AmountTooLow(amount));
        require(amount % BALANCE_COMPACT_PRECISION == 0, WrongAmountPrecision());
        // make sure validator exists at least
        Validator memory validator = $._validatorsMap[fromValidator];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(fromValidator));
        uint64 beforeEpoch = _nextEpoch();
        // Lets upgrade next snapshot parameters:
        // + find snapshot for the next epoch after current block
        // + increase total delegated amount in the next epoch for this validator
        // + re-save validator because last affected epoch might change
        ValidatorSnapshot storage validatorSnapshot = _touchValidatorSnapshot(validator, beforeEpoch);
        require(validatorSnapshot.totalDelegated >= uint112(amount / BALANCE_COMPACT_PRECISION), InsufficientBalance());
        validatorSnapshot.totalDelegated -= uint112(amount / BALANCE_COMPACT_PRECISION);
        $._validatorsMap[fromValidator] = validator;
        // if last pending delegate has the same next epoch then its safe to just increase total
        // staked amount because it can't affect current validator set, but otherwise we must create
        // new record in delegation queue with the last epoch (delegations are ordered by epoch)
        ValidatorDelegation storage delegation = $._validatorDelegations[fromValidator][toDelegator];
        require(delegation.delegateQueue.length > 0, DelegationQueueEmpty());
        DelegationOpDelegate storage recentDelegateOp = delegation.delegateQueue[delegation.delegateQueue.length - 1];
        require(recentDelegateOp.amount >= uint112(amount / BALANCE_COMPACT_PRECISION), InsufficientBalance());
        uint112 nextDelegatedAmount = recentDelegateOp.amount - uint112(amount / BALANCE_COMPACT_PRECISION);
        if (recentDelegateOp.epoch >= beforeEpoch) {
            // decrease total delegated amount for the next epoch
            recentDelegateOp.amount = nextDelegatedAmount;
        } else {
            // there is no pending delegations, so lets create the new one with the new amount
            delegation.delegateQueue.push(DelegationOpDelegate({epoch: beforeEpoch, amount: nextDelegatedAmount}));
        }
        // create new undelegate queue operation with soft lock
        delegation.undelegateQueue.push(
            DelegationOpUndelegate({
                amount: uint112(amount / BALANCE_COMPACT_PRECISION),
                epoch: beforeEpoch + _chainConfigContract.getUndelegatePeriod()
            })
        );
        // emit event with the next epoch number
        emit Undelegated(fromValidator, toDelegator, amount, beforeEpoch);
    }

    function _claimDelegatorRewardsAndPendingUndelegates(
        address validator,
        address delegator,
        uint64 beforeEpochExclude,
        ClaimMode claimMode
    ) internal {
        StakingStorage storage $ = _getStakingStorage();
        ValidatorDelegation storage delegation = $._validatorDelegations[validator][delegator];
        uint256 availableFunds = 0;
        // process delegate queue to calculate staking rewards
        uint64 delegateGap = delegation.delegateGap;
        for (uint256 queueLength = delegation.delegateQueue.length; delegateGap < queueLength; ) {
            DelegationOpDelegate memory delegateOp = delegation.delegateQueue[delegateGap];
            if (delegateOp.epoch >= beforeEpochExclude) {
                break;
            }
            uint256 voteChangedAtEpoch = 0;
            if (delegateGap < queueLength - 1) {
                voteChangedAtEpoch = delegation.delegateQueue[delegateGap + 1].epoch;
            }
            for (
                ;
                delegateOp.epoch < beforeEpochExclude && (voteChangedAtEpoch == 0 || delegateOp.epoch < voteChangedAtEpoch);
                delegateOp.epoch++
            ) {
                ValidatorSnapshot memory validatorSnapshot = $._validatorSnapshots[validator][delegateOp.epoch];
                if (validatorSnapshot.totalDelegated == 0) {
                    continue;
                }
                (uint256 delegatorFee, ,  /*uint256 ownerFee*/ /*uint256 systemFee*/) = _calcValidatorSnapshotEpochPayout(validatorSnapshot);
                availableFunds += (delegatorFee * delegateOp.amount) / validatorSnapshot.totalDelegated;
            }
            // if we have reached end of the delegation list then lets stay on the last item, but with updated latest processed epoch
            if (delegateGap >= queueLength - 1) {
                delegation.delegateQueue[delegateGap] = delegateOp;
                break;
            }
            delete delegation.delegateQueue[delegateGap];
            ++delegateGap;
        }
        delegation.delegateGap = delegateGap;
        // process all items from undelegate queue
        uint64 undelegateGap = delegation.undelegateGap;
        for (uint256 queueLength = delegation.undelegateQueue.length; undelegateGap < queueLength; ) {
            DelegationOpUndelegate memory undelegateOp = delegation.undelegateQueue[undelegateGap];
            if (undelegateOp.epoch > beforeEpochExclude) {
                break;
            }
            availableFunds += uint256(undelegateOp.amount) * BALANCE_COMPACT_PRECISION;
            delete delegation.undelegateQueue[undelegateGap];
            ++undelegateGap;
        }
        delegation.undelegateGap = undelegateGap;
        // send available for claim funds to delegator
        if (claimMode == ClaimMode.Transfer) {
            // for transfer claim mode just all rewards to the user
            _safeTransfer(delegator, availableFunds);
            // emit event
            emit Claimed(validator, delegator, availableFunds, beforeEpochExclude);
        } else if (claimMode == ClaimMode.Redelegate) {
            (uint256 amountToStake, uint256 rewardsDust) = _calcAvailableForRedelegateAmount(availableFunds);
            // if we have something to re-stake then delegate it to the validator
            if (amountToStake > 0) {
                _delegateTo(delegator, validator, amountToStake, false);
            }
            // if we have dust from staking then send it to user
            if (rewardsDust > 0) {
                _safeTransfer(delegator, rewardsDust);
            }
            // emit event
            emit Redelegated(validator, delegator, amountToStake, rewardsDust, beforeEpochExclude);
        } else {
            // this case is not possible, no error for less bytecode
            revert NotEnoughBalance();
        }
    }

    function _calcDelegatorRewardsAndPendingUndelegates(
        address validator,
        address delegator,
        uint64 beforeEpoch
    ) internal view returns (uint256) {
        StakingStorage storage $ = _getStakingStorage();
        ValidatorDelegation memory delegation = $._validatorDelegations[validator][delegator];
        uint256 availableFunds = 0;
        // process delegate queue to calculate staking rewards
        while (delegation.delegateGap < delegation.delegateQueue.length) {
            DelegationOpDelegate memory delegateOp = delegation.delegateQueue[delegation.delegateGap];
            if (delegateOp.epoch >= beforeEpoch) {
                break;
            }
            uint256 voteChangedAtEpoch = 0;
            if (delegation.delegateGap < delegation.delegateQueue.length - 1) {
                voteChangedAtEpoch = delegation.delegateQueue[delegation.delegateGap + 1].epoch;
            }
            for (; delegateOp.epoch < beforeEpoch && (voteChangedAtEpoch == 0 || delegateOp.epoch < voteChangedAtEpoch); delegateOp.epoch++) {
                ValidatorSnapshot memory validatorSnapshot = $._validatorSnapshots[validator][delegateOp.epoch];
                if (validatorSnapshot.totalDelegated == 0) {
                    continue;
                }
                (uint256 delegatorFee, ,  /*uint256 ownerFee*/ /*uint256 systemFee*/) = _calcValidatorSnapshotEpochPayout(validatorSnapshot);
                availableFunds += (delegatorFee * delegateOp.amount) / validatorSnapshot.totalDelegated;
            }
            ++delegation.delegateGap;
        }
        // process all items from undelegate queue
        while (delegation.undelegateGap < delegation.undelegateQueue.length) {
            DelegationOpUndelegate memory undelegateOp = delegation.undelegateQueue[delegation.undelegateGap];
            if (undelegateOp.epoch > beforeEpoch) {
                break;
            }
            availableFunds += uint256(undelegateOp.amount) * BALANCE_COMPACT_PRECISION;
            ++delegation.undelegateGap;
        }
        // return available for claim funds
        return availableFunds;
    }

    function _claimValidatorOwnerRewards(Validator storage validator, uint64 beforeEpoch) internal {
        StakingStorage storage $ = _getStakingStorage();
        uint256 availableFunds = 0;
        uint256 systemFee = 0;
        uint64 claimAt = validator.claimedAt;
        for (; claimAt < beforeEpoch; claimAt++) {
            ValidatorSnapshot memory validatorSnapshot = $._validatorSnapshots[validator.validatorAddress][claimAt];
            ( /*uint256 delegatorFee*/, uint256 ownerFee, uint256 slashingFee) = _calcValidatorSnapshotEpochPayout(validatorSnapshot);
            availableFunds += ownerFee;
            systemFee += slashingFee;
        }
        validator.claimedAt = claimAt;
        _safeTransfer(validator.ownerAddress, availableFunds);
        // if we have system fee then pay it to treasury account
        if (systemFee > 0) {
            _stakingToken.forceApprove(address(_systemRewardContract), systemFee);
            _systemRewardContract.deposit(systemFee);
        }
        emit ValidatorOwnerClaimed(validator.validatorAddress, availableFunds, beforeEpoch);
    }

    function _calcValidatorOwnerRewards(Validator memory validator, uint64 beforeEpoch) internal view returns (uint256) {
        StakingStorage storage $ = _getStakingStorage();
        uint256 availableFunds = 0;
        for (; validator.claimedAt < beforeEpoch; validator.claimedAt++) {
            ValidatorSnapshot memory validatorSnapshot = $._validatorSnapshots[validator.validatorAddress][validator.claimedAt];
            ( /*uint256 delegatorFee*/, uint256 ownerFee,  /*uint256 systemFee*/) = _calcValidatorSnapshotEpochPayout(validatorSnapshot);
            availableFunds += ownerFee;
        }
        return availableFunds;
    }

    function _calcValidatorSnapshotEpochPayout(
        ValidatorSnapshot memory validatorSnapshot
    ) internal view returns (uint256 delegatorFee, uint256 ownerFee, uint256 systemFee) {
        // detect validator slashing to transfer all rewards to treasury
        if (validatorSnapshot.slashesCount >= _chainConfigContract.getMisdemeanorThreshold()) {
            return (delegatorFee = 0, ownerFee = 0, systemFee = validatorSnapshot.totalRewards);
        } else if (validatorSnapshot.totalDelegated == 0) {
            return (delegatorFee = 0, ownerFee = validatorSnapshot.totalRewards, systemFee = 0);
        }
        // ownerFee_(18+4-4=18) = totalRewards_18 * commissionRate_4 / 1e4
        ownerFee = (uint256(validatorSnapshot.totalRewards) * validatorSnapshot.commissionRate) / 1e4;
        // delegatorRewards = totalRewards - ownerFee
        delegatorFee = validatorSnapshot.totalRewards - ownerFee;
        // default system fee is zero for epoch
        systemFee = 0;
    }

    /// @inheritdoc IStaking
    function registerValidator(address validatorAddress, uint16 commissionRate, uint256 initialStake) external override {
        // // initial stake amount should be greater than minimum validator staking amount
        require(initialStake >= _chainConfigContract.getMinValidatorStakeAmount(), InitialStakeTooLow(initialStake));
        require(initialStake % BALANCE_COMPACT_PRECISION == 0, WrongAmountPrecision());
        _stakingToken.safeTransferFrom(msg.sender, address(this), initialStake);
        // add new validator as pending
        _addValidator(validatorAddress, msg.sender, ValidatorStatus.Pending, commissionRate, initialStake, _nextEpoch());
    }

    /// @inheritdoc IStaking
    function addValidator(address account) external virtual override onlyFromGovernance {
        _addValidator(account, account, ValidatorStatus.Active, 0, 0, _nextEpoch());
    }

    function _addValidator(
        address validatorAddress,
        address validatorOwner,
        ValidatorStatus status,
        uint16 commissionRate,
        uint256 initialStake,
        uint64 sinceEpoch
    ) internal {
        StakingStorage storage $ = _getStakingStorage();
        // validator commission rate
        require(commissionRate >= COMMISSION_RATE_MIN_VALUE && commissionRate <= COMMISSION_RATE_MAX_VALUE, BadCommissionRate(commissionRate));

        // init validator default params
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status == ValidatorStatus.NotFound, ValidatorAlreadyExists(validatorAddress));
        validator.validatorAddress = validatorAddress;
        validator.ownerAddress = validatorOwner;
        validator.status = status;
        validator.changedAt = sinceEpoch;
        $._validatorsMap[validatorAddress] = validator;
        // save validator owner
        require($._validatorOwners[validatorOwner] == address(0x00), ValidatorOwnerAlreadyInUse(validatorAddress));
        $._validatorOwners[validatorOwner] = validatorAddress;
        // add new validator to array
        if (status == ValidatorStatus.Active) {
            $._activeValidatorsList.push(validatorAddress);
        }
        // push initial validator snapshot at zero epoch with default params
        $._validatorSnapshots[validatorAddress][sinceEpoch] = ValidatorSnapshot(
            0,
            uint112(initialStake / BALANCE_COMPACT_PRECISION),
            0,
            commissionRate
        );
        // delegate initial stake to validator owner
        ValidatorDelegation storage delegation = $._validatorDelegations[validatorAddress][validatorOwner];
        require(delegation.delegateQueue.length == 0, DelegationQueueNotEmpty(delegation.delegateQueue.length));
        delegation.delegateQueue.push(DelegationOpDelegate(uint112(initialStake / BALANCE_COMPACT_PRECISION), sinceEpoch));

        emit ValidatorAdded(validatorAddress, validatorOwner, uint8(status), commissionRate);
    }

    /// @inheritdoc IStaking
    function removeValidator(address account) external virtual override onlyFromGovernance {
        _removeValidator(account);
    }

    function _removeValidatorFromActiveList(address validatorAddress) internal {
        StakingStorage storage $ = _getStakingStorage();
        // find index of validator in validator set
        int256 indexOf = -1;
        for (uint256 i = 0; i < $._activeValidatorsList.length; i++) {
            if ($._activeValidatorsList[i] != validatorAddress) continue;
            indexOf = int256(i);
            break;
        }
        // remove validator from array (since we remove only active it might not exist in the list)
        if (indexOf >= 0) {
            if ($._activeValidatorsList.length > 1 && uint256(indexOf) != $._activeValidatorsList.length - 1) {
                $._activeValidatorsList[uint256(indexOf)] = $._activeValidatorsList[$._activeValidatorsList.length - 1];
            }
            $._activeValidatorsList.pop();
        }
    }

    function _removeValidator(address validatorAddress) internal {
        StakingStorage storage $ = _getStakingStorage();
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress));
        // check if validator has active delegations
        require(_totalDelegatedToValidator(validator) == 0, ValidatorHasActiveDelegations(validatorAddress));
        // remove validator from active list if exists
        _removeValidatorFromActiveList(validatorAddress);
        // remove from validators map
        delete $._validatorOwners[validator.ownerAddress];
        delete $._validatorsMap[validatorAddress];
        // emit event about it
        emit ValidatorRemoved(validatorAddress);
    }

    /// @inheritdoc IStaking
    function activateValidator(address validator) external virtual override onlyFromGovernance {
        _activateValidator(validator);
    }

    function _activateValidator(address validatorAddress) internal {
        StakingStorage storage $ = _getStakingStorage();
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status == ValidatorStatus.Pending, NotPendingValidator(validatorAddress));
        $._activeValidatorsList.push(validatorAddress);
        validator.status = ValidatorStatus.Active;
        $._validatorsMap[validatorAddress] = validator;
        ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(validator, _nextEpoch());
        emit ValidatorModified(validatorAddress, validator.ownerAddress, uint8(validator.status), snapshot.commissionRate);
    }

    /// @inheritdoc IStaking
    function disableValidator(address validator) external virtual override onlyFromGovernance {
        _disableValidator(validator);
    }

    function _disableValidator(address validatorAddress) internal {
        StakingStorage storage $ = _getStakingStorage();
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status == ValidatorStatus.Active, NotActiveValidator());
        _removeValidatorFromActiveList(validatorAddress);
        validator.status = ValidatorStatus.Pending;
        $._validatorsMap[validatorAddress] = validator;
        ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(validator, _nextEpoch());
        emit ValidatorModified(validatorAddress, validator.ownerAddress, uint8(validator.status), snapshot.commissionRate);
    }

    /// @inheritdoc IStaking
    function changeValidatorCommissionRate(address validatorAddress, uint16 commissionRate) external {
        StakingStorage storage $ = _getStakingStorage();
        require(commissionRate >= COMMISSION_RATE_MIN_VALUE && commissionRate <= COMMISSION_RATE_MAX_VALUE, BadCommissionRate(commissionRate));
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress));
        require(validator.ownerAddress == msg.sender, OnlyValidatorOwner(validator.ownerAddress));
        ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(validator, _nextEpoch());
        snapshot.commissionRate = commissionRate;
        $._validatorsMap[validatorAddress] = validator;
        emit ValidatorModified(validator.validatorAddress, validator.ownerAddress, uint8(validator.status), commissionRate);
    }

    /// @inheritdoc IStaking
    function changeValidatorOwner(address validatorAddress, address newOwner) external override {
        StakingStorage storage $ = _getStakingStorage();
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.ownerAddress == msg.sender, OnlyValidatorOwner(validator.ownerAddress));
        require(newOwner != address(0), OwnerCantBeZero());
        require($._validatorOwners[newOwner] == address(0x00), ValidatorOwnerAlreadyInUse(validatorAddress));
        delete $._validatorOwners[validator.ownerAddress];
        validator.ownerAddress = newOwner;
        $._validatorOwners[newOwner] = validatorAddress;
        $._validatorsMap[validatorAddress] = validator;
        ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(validator, _nextEpoch());
        emit ValidatorModified(validator.validatorAddress, validator.ownerAddress, uint8(validator.status), snapshot.commissionRate);
    }

    /// @inheritdoc IStaking
    function isValidatorActive(address account) external view override returns (bool) {
        StakingStorage storage $ = _getStakingStorage();
        if ($._validatorsMap[account].status != ValidatorStatus.Active) {
            return false;
        }
        address[] memory topValidators = _getValidators();
        for (uint256 i = 0; i < topValidators.length; i++) {
            if (topValidators[i] == account) return true;
        }
        return false;
    }

    /// @inheritdoc IStaking
    function isValidator(address account) external view override returns (bool) {
        StakingStorage storage $ = _getStakingStorage();
        return $._validatorsMap[account].status != ValidatorStatus.NotFound;
    }

    function _getValidators() internal view returns (address[] memory) {
        StakingStorage storage $ = _getStakingStorage();
        uint256 n = $._activeValidatorsList.length;
        address[] memory orderedValidators = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            orderedValidators[i] = $._activeValidatorsList[i];
        }
        // we need to select k top validators out of n
        uint256 k = _chainConfigContract.getActiveValidatorsLength();
        if (k > n) {
            k = n;
        }
        for (uint256 i = 0; i < k; i++) {
            uint256 nextValidator = i;
            Validator memory currentMax = $._validatorsMap[orderedValidators[nextValidator]];
            for (uint256 j = i + 1; j < n; j++) {
                Validator memory current = $._validatorsMap[orderedValidators[j]];
                if (_totalDelegatedToValidator(currentMax) < _totalDelegatedToValidator(current)) {
                    nextValidator = j;
                    currentMax = current;
                }
            }
            address backup = orderedValidators[i];
            orderedValidators[i] = orderedValidators[nextValidator];
            orderedValidators[nextValidator] = backup;
        }
        // this is to cut array to first k elements without copying
        assembly {
            mstore(orderedValidators, k)
        }
        return orderedValidators;
    }

    function getValidators() external view override returns (address[] memory) {
        return _getValidators();
    }

    function deposit(address validatorAddress, uint256 amount) external virtual override onlyFromCoinbase onlyZeroGasPrice {
        _depositFee(validatorAddress, amount);
    }

    function _depositFee(address validatorAddress, uint256 amount) internal {
        StakingStorage storage $ = _getStakingStorage();
        require(amount > 0, DepositIsZero());
        _stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        // make sure validator is active
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress));
        uint64 epoch = _currentEpoch();
        // increase total pending rewards for validator for current epoch
        ValidatorSnapshot storage currentSnapshot = _touchValidatorSnapshot(validator, epoch);
        currentSnapshot.totalRewards += uint96(amount);
        // emit event
        emit ValidatorDeposited(validatorAddress, amount, epoch);
    }

    function getValidatorFee(address validatorAddress) external view override returns (uint256) {
        StakingStorage storage $ = _getStakingStorage();
        // make sure validator exists at least
        Validator memory validator = $._validatorsMap[validatorAddress];
        if (validator.status == ValidatorStatus.NotFound) {
            return 0;
        }
        // calc validator rewards
        return _calcValidatorOwnerRewards(validator, _currentEpoch());
    }

    function getPendingValidatorFee(address validatorAddress) external view override returns (uint256) {
        StakingStorage storage $ = _getStakingStorage();
        // make sure validator exists at least
        Validator memory validator = $._validatorsMap[validatorAddress];
        if (validator.status == ValidatorStatus.NotFound) {
            return 0;
        }
        // calc validator rewards
        return _calcValidatorOwnerRewards(validator, _nextEpoch());
    }

    function claimValidatorFee(address validatorAddress) external override {
        StakingStorage storage $ = _getStakingStorage();
        // make sure validator exists at least
        Validator storage validator = $._validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress));
        // settle all validator fees to the owner and slashed fees to the system reward contract
        _claimValidatorOwnerRewards(validator, _currentEpoch());
    }

    function claimValidatorFeeAtEpoch(address validatorAddress, uint64 beforeEpoch) external override {
        StakingStorage storage $ = _getStakingStorage();
        // make sure validator exists at least
        Validator storage validator = $._validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress));
        // we disallow to claim rewards from future epochs
        require(beforeEpoch <= _currentEpoch(), InvalidClaimEpoch());
        // settle validator fees to the owner and slashed fees to the system reward contract
        _claimValidatorOwnerRewards(validator, beforeEpoch);
    }

    function getDelegatorFee(address validatorAddress, address delegatorAddress) external view override returns (uint256) {
        return _calcDelegatorRewardsAndPendingUndelegates(validatorAddress, delegatorAddress, _currentEpoch());
    }

    function getPendingDelegatorFee(address validatorAddress, address delegatorAddress) external view override returns (uint256) {
        return _calcDelegatorRewardsAndPendingUndelegates(validatorAddress, delegatorAddress, _nextEpoch());
    }

    function claimDelegatorFee(address validatorAddress) external override {
        // claim all confirmed delegator fees including undelegates
        _claimDelegatorRewardsAndPendingUndelegates(validatorAddress, msg.sender, _currentEpoch(), ClaimMode.Transfer);
    }

    function _calcAvailableForRedelegateAmount(uint256 claimableRewards) internal view returns (uint256 amountToStake, uint256 rewardsDust) {
        // for redelegate we must split amount into stake-able and dust
        amountToStake = (claimableRewards / BALANCE_COMPACT_PRECISION) * BALANCE_COMPACT_PRECISION;
        if (amountToStake < _chainConfigContract.getMinStakingAmount()) {
            return (0, claimableRewards);
        }
        // if we have dust remaining after re-stake then send it to user (we can't keep it in the contract)
        return (amountToStake, claimableRewards - amountToStake);
    }

    function calcAvailableForRedelegateAmount(
        address validator,
        address delegator
    ) external view override returns (uint256 amountToStake, uint256 rewardsDust) {
        uint256 claimableRewards = _calcDelegatorRewardsAndPendingUndelegates(validator, delegator, _currentEpoch());
        return _calcAvailableForRedelegateAmount(claimableRewards);
    }

    function redelegateDelegatorFee(address validator) external override {
        // claim rewards in the redelegate mode (check function code for more info)
        _claimDelegatorRewardsAndPendingUndelegates(validator, msg.sender, _currentEpoch(), ClaimMode.Redelegate);
    }

    function claimDelegatorFeeAtEpoch(address validatorAddress, uint64 beforeEpoch) external override {
        // make sure delegator can't claim future epochs
        require(beforeEpoch <= _currentEpoch(), InvalidClaimEpoch());
        // claim all confirmed delegator fees including undelegates
        _claimDelegatorRewardsAndPendingUndelegates(validatorAddress, msg.sender, beforeEpoch, ClaimMode.Transfer);
    }

    function _safeTransfer(address recipient, uint256 amount) internal {
        if (amount > 0) {
            _stakingToken.safeTransfer(recipient, amount);
        }
    }

    function slash(address validatorAddress) external virtual override onlyFromSlashingIndicator {
        _slashValidator(validatorAddress);
    }

    // ============================
    //  Consensus Keys (v1 — minimal registry, no on-chain crypto)
    // ============================

    /// @notice Register consensus keys for `validator` with on-chain
    ///         Proof-of-Possession. One-shot — no rotation in v1.
    /// @param blsPubkeyUncompressed 256 B EIP-2537 G2 — compressed on-chain
    ///                              to the stored 96 B identity.
    /// @param blsPoPUncompressed    128 B EIP-2537 G1 PoP signature — verify-only.
    function setConsensusKeys(
        address validatorAddress,
        bytes calldata blsPubkeyUncompressed,
        bytes calldata blsPoPUncompressed,
        bytes32 peerPubkey
    ) external override {
        if (_getEquivocationStorage().tombstoned[validatorAddress]) {
            revert AlreadySlashedForEquivocation(validatorAddress);
        }
        StakingStorage storage $s = _getStakingStorage();
        Validator memory v = $s._validatorsMap[validatorAddress];
        if (v.status == ValidatorStatus.NotFound) revert ValidatorNotFound(validatorAddress);
        if (msg.sender != v.ownerAddress) revert OnlyValidatorOwner(v.ownerAddress);
        if (blsPubkeyUncompressed.length != 256 || blsPoPUncompressed.length != 128) {
            revert InvalidConsensusKeyEncoding();
        }

        ConsensusKeysStorage storage $ck = _getConsensusKeysStorage();
        if ($ck.consensusKeys[validatorAddress].blsPubkey.length != 0) {
            revert ConsensusKeysAlreadySet(validatorAddress);
        }

        address verifierAddr = _chainConfigContract.getBlsVerifier();
        if (verifierAddr == address(0)) revert BlsVerifierNotConfigured();
        IBLS12381Verifier verifier = IBLS12381Verifier(verifierAddr);

        // Derive the authoritative compressed identity on-chain: it becomes
        // BOTH the PoP signed message and the stored key. No compare — PoP
        // self-proves possession; there is no pre-existing anchor at
        // registration. PoP: namespace = base fluent_namespace (NO subject
        // suffix); DST = BLS_POP_… ; one G1 sig.
        bytes memory blsPubkey = verifier.compressG2(blsPubkeyUncompressed);

        if (!verifier.verify(_fluentNamespace(), blsPubkey, BLS_POP_DST, blsPoPUncompressed, blsPubkeyUncompressed)) {
            revert InvalidProofOfPossession(validatorAddress);
        }

        uint64 activationEpoch = _nextEpoch();
        $ck.consensusKeys[validatorAddress] =
            IStaking.ConsensusKeys({blsPubkey: blsPubkey, peerPubkey: peerPubkey, activationEpoch: activationEpoch});

        emit ConsensusKeysSet(validatorAddress, blsPubkey, peerPubkey, activationEpoch);
    }

    function getConsensusKeys(address validatorAddress) external view override returns (IStaking.ConsensusKeys memory) {
        return _getConsensusKeysStorage().consensusKeys[validatorAddress];
    }

    function getValidatorsWithKeys()
        external
        view
        override
        returns (address[] memory addrs, IStaking.ConsensusKeys[] memory keys)
    {
        addrs = _getValidators();
        keys = new IStaking.ConsensusKeys[](addrs.length);
        ConsensusKeysStorage storage $ck = _getConsensusKeysStorage();
        for (uint256 i = 0; i < addrs.length; i++) {
            keys[i] = $ck.consensusKeys[addrs[i]];
        }
    }

    function _slashValidator(address validatorAddress) internal {
        StakingStorage storage $ = _getStakingStorage();
        // make sure validator exists
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress));
        uint64 epoch = _currentEpoch();
        // increase slashes for current epoch
        ValidatorSnapshot storage currentSnapshot = _touchValidatorSnapshot(validator, epoch);
        uint32 slashesCount = currentSnapshot.slashesCount + 1;
        currentSnapshot.slashesCount = slashesCount;
        // validator state might change, lets update it
        $._validatorsMap[validatorAddress] = validator;
        // if validator has a lot of misses then put it in jail for 1 week (if epoch is 1 day)
        if (slashesCount == _chainConfigContract.getFelonyThreshold()) {
            validator.jailedBefore = _currentEpoch() + _chainConfigContract.getValidatorJailEpochLength();
            validator.status = ValidatorStatus.Jail;
            _removeValidatorFromActiveList(validatorAddress);
            $._validatorsMap[validatorAddress] = validator;
            emit ValidatorJailed(validatorAddress, epoch);
        }

        emit ValidatorSlashed(validatorAddress, slashesCount, epoch);
    }

    // ============================
    //  Epoch committee freeze + signer index resolution
    // ============================

    /// @notice Freezes the canonical consensus committee for the current epoch.
    /// @dev System call: the sequencer injects this once on the first block of
    ///      a new epoch (zero gas price, from coinbase), passing the SAME
    ///      ordered committee it feeds Commonware `Oracle::track`. The contract
    ///      does NOT trust that input: it verifies `committee` is exactly the
    ///      keyed subset of `_getValidators()` top-k, strictly ascending by
    ///      `peerPubkey` (the unique canonical Simplex committee order). The sequencer
    ///      has zero freedom — it can only submit the one array the contract
    ///      would itself derive; off-chain sorting just saves the O(m^2)
    ///      on-chain sort. Idempotent + strictly monotonic — a re-call for an
    ///      already/older epoch is a no-op; a missed epoch has no record (its
    ///      evidence is unslashable, by design).
    /// @param committee Validators in ascending-`peerPubkey` order. Reverts
    ///        unless it equals the keyed top-k set exactly.
    function commitEpochCommittee(address[] calldata committee)
        external
        virtual
        override
        onlyFromCoinbase
        onlyZeroGasPrice
    {
        EpochCommitteeStorage storage $ec = _getEpochCommitteeStorage();
        uint64 epoch = _currentEpoch();
        // idempotent + strictly monotonic, genesis-safe (sentinel +1):
        // refuse any epoch at or below the latest committed one.
        if ($ec.lastCommittedEpochP1 != 0 && epoch + 1 <= $ec.lastCommittedEpochP1) {
            return;
        }

        // 1. mark the keyed subset of the same top-k set the reader is fed via
        //    getValidatorsWithKeys() into a transient set; count it.
        address[] memory top = _getValidators();
        ConsensusKeysStorage storage $ck = _getConsensusKeysStorage();
        uint256 m = 0;
        for (uint256 i = 0; i < top.length; i++) {
            if ($ck.consensusKeys[top[i]].peerPubkey != bytes32(0)) {
                _tMark(top[i]);
                m++;
            }
        }

        // 2. verify the submitted array IS that set, in strict ascending
        //    peerPubkey order. length + (∈set) + (strictly ascending ⇒ distinct)
        //    ⇒ by pigeonhole it is exactly the keyed top-k set, canonically
        //    ordered. No trust in the sequencer-supplied ordering.
        if (committee.length != m) revert CommitteeLengthMismatch(m, committee.length);
        address[] storage stored = $ec.committee[epoch];
        bytes32 prev = bytes32(0);
        for (uint256 i = 0; i < committee.length; i++) {
            address v = committee[i];
            bytes32 peer = $ck.consensusKeys[v].peerPubkey;
            if (peer == bytes32(0)) revert CommitteeMemberKeyless(v);
            if (!_tMarked(v)) revert CommitteeMemberNotInActiveSet(v);
            if (peer <= prev) revert CommitteeNotStrictlyAscending(v);
            _tUnmark(v); // consume → a duplicate address fails _tMarked next time
            prev = peer;
            stored.push(v);
        }
        $ec.lastCommittedEpochP1 = epoch + 1;

        // 3. prune the stale window. A cursor advances even across skipped
        //    commits, so storage cannot leak under irregular cadence; the
        //    per-call delete count is bounded to cap gas.
        _pruneStaleCommittees($ec, epoch);

        emit EpochCommitteeCommitted(epoch, committee);
    }

    /// @dev Bounded prune of every retained-window-expired epoch since the
    ///      last prune cursor (handles skipped commits without leaking).
    function _pruneStaleCommittees(EpochCommitteeStorage storage $ec, uint64 epoch) private {
        uint64 retention = uint64(_chainConfigContract.getUndelegatePeriod()) + EPOCH_COMMITTEE_RETENTION_MARGIN;
        if (epoch <= retention) return;
        uint64 pruneTo = epoch - retention - 1; // newest epoch now outside the window
        uint64 from = $ec.prunedUpToP1; // already-pruned through (from - 1)
        uint64 maxDeletes = 16; // gas cap
        uint64 deleted = 0;
        while (from <= pruneTo && deleted < maxDeletes) {
            if ($ec.committee[from].length != 0) {
                delete $ec.committee[from];
            }
            from++;
            deleted++;
        }
        $ec.prunedUpToP1 = from;
    }

    // Transient membership set (EIP-1153; evm_version=prague). Keyed by raw
    // address — no other transient storage exists in this contract, so there
    // is no slot collision. Auto-clears at end of tx.
    function _tMark(address a) private {
        assembly {
            tstore(a, 1)
        }
    }

    function _tUnmark(address a) private {
        assembly {
            tstore(a, 0)
        }
    }

    function _tMarked(address a) private view returns (bool r) {
        assembly {
            r := tload(a)
        }
    }

    /// @notice Resolves a Simplex signer index for a past epoch to the
    ///         validator address, using that epoch's frozen committee.
    function resolveSigner(uint64 epoch, uint32 signerIdx) external view override returns (address) {
        return _resolveSignerToValidator(epoch, signerIdx);
    }

    function _resolveSignerToValidator(uint64 epoch, uint32 signerIdx) internal view returns (address) {
        address[] storage c = _getEpochCommitteeStorage().committee[epoch];
        uint256 n = c.length;
        if (n == 0) revert EpochCommitteeNotCommitted(epoch);
        if (signerIdx >= n) revert SignerIndexOutOfRange(epoch, signerIdx, n);
        return c[signerIdx];
    }

    /// @notice Returns the frozen committee for `epoch` (Simplex committee order), or
    ///         empty if never committed. Consumed by fluent-staking-reader.
    function getEpochCommittee(uint64 epoch) external view override returns (address[] memory) {
        return _getEpochCommitteeStorage().committee[epoch];
    }

    // ============ Equivocation slashing ============

    /// @dev fluent_namespace(chain_id) = "FLUENT_DPOS_V1_" ‖ chain_id u64 BE (23 B).
    ///      `block.chainid` == the Simplex consensus node `chain_id` (cross-component
    ///      invariant; the conformance corpus uses 20994).
    function _fluentNamespace() internal view returns (bytes memory) {
        return abi.encodePacked(bytes15("FLUENT_DPOS_V1_"), bytes8(uint64(block.chainid)));
    }

    /// @dev Per-subject namespace: base ‖ subject suffix (plain concat, no
    ///      length prefix — mirrors commonware_utils::union).
    function _nsForKind(uint8 kind) internal view returns (bytes memory) {
        bytes memory base = _fluentNamespace();
        if (kind == 0) return bytes.concat(base, "_NOTARIZE");
        if (kind == 1) return bytes.concat(base, "_NULLIFY");
        return bytes.concat(base, "_FINALIZE"); // kind == 2
    }

    function _decoder() internal view returns (SimplexEvidenceDecoder) {
        return SimplexEvidenceDecoder(_chainConfigContract.getEvidenceDecoder());
    }

    function slashEquivocationNotarize(
        bytes calldata evidence,
        bytes calldata pkUncompressed,
        bytes calldata sig1Uncompressed,
        bytes calldata sig2Uncompressed
    ) external override {
        _slashEquivocation(
            _decoder().decodeConflictingNotarize(evidence), pkUncompressed, sig1Uncompressed, sig2Uncompressed
        );
    }

    function slashEquivocationFinalize(
        bytes calldata evidence,
        bytes calldata pkUncompressed,
        bytes calldata sig1Uncompressed,
        bytes calldata sig2Uncompressed
    ) external override {
        _slashEquivocation(
            _decoder().decodeConflictingFinalize(evidence), pkUncompressed, sig1Uncompressed, sig2Uncompressed
        );
    }

    function slashEquivocationNullifyFinalize(
        bytes calldata evidence,
        bytes calldata pkUncompressed,
        bytes calldata sig1Uncompressed,
        bytes calldata sig2Uncompressed
    ) external override {
        _slashEquivocation(
            _decoder().decodeNullifyFinalize(evidence), pkUncompressed, sig1Uncompressed, sig2Uncompressed
        );
    }

    function _slashEquivocation(
        SimplexEvidenceDecoder.Decoded memory ev,
        bytes calldata pkUncompressed,
        bytes calldata sig1Unc,
        bytes calldata sig2Unc
    ) internal {
        address validator = _resolveSignerToValidator(ev.epoch, ev.signerIdx);

        EquivocationStorage storage $eq = _getEquivocationStorage();
        if ($eq.tombstoned[validator]) revert AlreadySlashedForEquivocation(validator); // replay guard

        bytes memory pk96 = _getConsensusKeysStorage().consensusKeys[validator].blsPubkey;
        if (pk96.length != BLS_PUBKEY_LENGTH) revert ConsensusKeysNotSet(validator);

        IBLS12381Verifier verifier = IBLS12381Verifier(_chainConfigContract.getBlsVerifier());

        // Bind caller-supplied uncompressed inputs to the trust anchors:
        //  - pk   -> the validator's registered compressed key
        //  - sigN -> the exact 48 B compressed signature inside the evidence
        if (keccak256(verifier.compressG2(pkUncompressed)) != keccak256(pk96)) {
            revert EquivocationKeyMismatch();
        }
        if (
            keccak256(verifier.compressG1(sig1Unc)) != keccak256(ev.sig1)
                || keccak256(verifier.compressG1(sig2Unc)) != keccak256(ev.sig2)
        ) revert EquivocationSignatureInvalid();

        bool ok1 = verifier.verify(_nsForKind(ev.kind1), ev.msg1, BLS_SIG_DST, sig1Unc, pkUncompressed);
        bool ok2 = verifier.verify(_nsForKind(ev.kind2), ev.msg2, BLS_SIG_DST, sig2Unc, pkUncompressed);
        if (!ok1 || !ok2) revert EquivocationSignatureInvalid();

        // CEI: tombstone before any state-changing penalty.
        $eq.tombstoned[validator] = true;
        _penalizeEquivocation(validator);
        emit EquivocationSlashed(validator, ev.epoch, msg.sender);
    }

    /// @dev Not the misdemeanor/felony liveness counter — equivocation is an
    ///      immediate permanent jail. Stake-% seizure is intentionally not
    ///      implemented (deferred).
    function _penalizeEquivocation(address validatorAddress) internal {
        StakingStorage storage $ = _getStakingStorage();
        Validator memory v = $._validatorsMap[validatorAddress];
        if (v.status == ValidatorStatus.NotFound) revert ValidatorNotFound(validatorAddress);
        if (v.status == ValidatorStatus.Active) _removeValidatorFromActiveList(validatorAddress);
        v.status = ValidatorStatus.Jail;
        // No jailedBefore sentinel: the `tombstoned` flag set by
        // `_slashEquivocation` is the single never-release mechanism —
        // unconditional and first in `releaseValidatorFromJail`.
        $._validatorsMap[validatorAddress] = v;
        emit ValidatorJailed(validatorAddress, _currentEpoch());
    }
}
