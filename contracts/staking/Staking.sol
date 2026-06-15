// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStaking, IStakingEvents, IStakingErrors} from "./interfaces/IStaking.sol";
import {ISystemReward} from "./interfaces/ISystemReward.sol";
import {IStakingPool} from "./interfaces/IStakingPool.sol";
import {IFluentGovernance} from "./interfaces/IFluentGovernance.sol";
import {IChainConfig} from "./interfaces/IChainConfig.sol";
import {StakingContext} from "./StakingContext.sol";
import {StakingLayout} from "./StakingLayout.sol";
import {StakingDpos} from "./StakingDpos.sol";
import {StakingEconomics} from "./StakingEconomics.sol";

/**
 * @title Validator staking
 * @author Fluent Labs
 * @notice Manages validator registration, delegation, undelegation, commission, reward claims, active set ordering, and slashing.
 * @dev Uses epoch snapshots and compacted balances to preserve historical accounting without storing full uint256 stake values.
 */
contract Staking is IStaking, StakingContext {
    using SafeERC20 for IERC20;

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

    /// @notice V1: liveness slasher predeploy address. ACL'd as a private
    ///         immutable here rather than as a `StakingContext` field so the
    ///         constructor cascade is isolated to `Staking.sol`.
    address private immutable _livenessSlashingAddr;

    constructor(
        IStaking stakingContract,
        ISystemReward systemRewardContract,
        IStakingPool stakingPoolContract,
        IFluentGovernance governanceContract,
        IChainConfig chainConfigContract,
        IERC20 stakingToken,
        address livenessSlashingAddr
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
        _livenessSlashingAddr = livenessSlashingAddr;
    }

    /// @dev Gates the
    ///      `LivenessSlashing` predeploy as the sole caller of
    ///      `slash`.
    modifier onlyFromLivenessSlashing() {
        require(msg.sender == _livenessSlashingAddr, OnlyLivenessSlashing());
        _;
    }

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
        for (uint256 i = 0; i < numValidators;) {
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
    function getValidatorDelegation(address validatorAddress, address delegator)
        external
        view
        override
        returns (uint256 delegatedAmount, uint64 atEpoch)
    {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        ValidatorDelegation memory delegation = $._validatorDelegations[validatorAddress][delegator];
        if (delegation.delegateQueue.length == 0) {
            return (delegatedAmount = 0, atEpoch = 0);
        }
        DelegationOpDelegate memory snapshot = delegation.delegateQueue[delegation.delegateQueue.length - 1];
        return (
            delegatedAmount = uint256(snapshot.amount) * StakingLayout.BALANCE_COMPACT_PRECISION,
            atEpoch = snapshot.epoch
        );
    }

    /// @inheritdoc IStaking
    function getValidatorStatus(address validatorAddress)
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
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        Validator memory validator = $._validatorsMap[validatorAddress];
        ValidatorSnapshot memory snapshot = $._validatorSnapshots[validator.validatorAddress][validator.changedAt];
        return (
            ownerAddress = validator.ownerAddress,
            status = uint8(validator.status),
            totalDelegated = uint256(snapshot.totalDelegated) * StakingLayout.BALANCE_COMPACT_PRECISION,
            slashesCount = snapshot.slashesCount,
            changedAt = validator.changedAt,
            jailedBefore = validator.jailedBefore,
            claimedAt = validator.claimedAt,
            commissionRate = snapshot.commissionRate,
            totalRewards = snapshot.totalRewards
        );
    }

    /// @inheritdoc IStaking
    function getValidatorStatusAtEpoch(address validatorAddress, uint64 epoch)
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
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        Validator memory validator = $._validatorsMap[validatorAddress];
        ValidatorSnapshot memory snapshot = StakingLayout.touchValidatorSnapshotImmutable($, validator, epoch);
        return (
            ownerAddress = validator.ownerAddress,
            status = uint8(validator.status),
            totalDelegated = uint256(snapshot.totalDelegated) * StakingLayout.BALANCE_COMPACT_PRECISION,
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
        return StakingLayout.stakingStorage()._validatorOwners[owner];
    }

    /// @inheritdoc IStaking
    function releaseValidatorFromJail(address validatorAddress) external {
        if (StakingLayout.equivocationStorage().tombstoned[validatorAddress]) {
            revert AlreadySlashedForEquivocation(validatorAddress);
        }
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
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
        return StakingLayout.totalDelegatedToValidatorAt(validator, _currentEpoch());
    }

    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function delegate(address validatorAddress, uint256 amount) external override {
        StakingEconomics.delegate(_chainConfigContract, _stakingToken, validatorAddress, amount);
    }

    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function undelegate(address validatorAddress, uint256 amount) external override {
        StakingEconomics.undelegate(_chainConfigContract, validatorAddress, amount);
    }

    function currentEpoch() external view returns (uint64) {
        return _currentEpoch();
    }

    function nextEpoch() external view returns (uint64) {
        return _nextEpoch();
    }

    function _currentEpoch() internal view returns (uint64) {
        // DPoS epochs are numbered relative to `dposActivationBlock` so a
        // Tempo→DPoS migration anchor at a high block becomes epoch 0 (see
        // ChainConfig.dposActivationBlock). Pre-activation blocks clamp to 0 —
        // reachable only in a predeploy window before the switch; in production
        // the contract is introduced at activation so block.number >= activation
        // always holds. activation == 0 ⇒ absolute numbering (degenerate).
        uint64 activation = _chainConfigContract.getDposActivationBlock();
        if (block.number < activation) {
            return 0;
        }
        return uint64((block.number - activation) / _chainConfigContract.getEpochBlockInterval());
    }

    function _nextEpoch() internal view returns (uint64) {
        return _currentEpoch() + 1;
    }

    /// @inheritdoc IStaking
    function registerValidator(address validatorAddress, uint16 commissionRate, uint256 initialStake)
        external
        override
    {
        // initial stake amount should be greater than minimum validator staking amount
        require(initialStake >= _chainConfigContract.getMinValidatorStakeAmount(), InitialStakeTooLow(initialStake));
        require(initialStake % StakingLayout.BALANCE_COMPACT_PRECISION == 0, WrongAmountPrecision());
        // Add the validator before pulling tokens so all validation and accounting complete first.
        _addValidator(validatorAddress, msg.sender, ValidatorStatus.Pending, commissionRate, initialStake, _nextEpoch());
        _stakingToken.safeTransferFrom(msg.sender, address(this), initialStake);
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
        require(validatorAddress != address(0), ZeroValidator());
        require(validatorOwner != address(0), ZeroOwner());
        require(initialStake % StakingLayout.BALANCE_COMPACT_PRECISION == 0, WrongAmountPrecision());
        // Runtime additions must not target a future epoch. Genesis initialization uses epoch 0
        // before the chain config contract exists at its predicted address.
        if (sinceEpoch > 0) {
            require(sinceEpoch <= _nextEpoch(), InvalidEpoch());
        }

        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        // validator commission rate
        require(
            commissionRate >= COMMISSION_RATE_MIN_VALUE && commissionRate <= COMMISSION_RATE_MAX_VALUE,
            BadCommissionRate(commissionRate)
        );

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
        $._validatorSnapshots[validatorAddress][sinceEpoch] =
            ValidatorSnapshot(0, uint112(initialStake / StakingLayout.BALANCE_COMPACT_PRECISION), 0, commissionRate);
        // delegate initial stake to validator owner
        ValidatorDelegation storage delegation = $._validatorDelegations[validatorAddress][validatorOwner];
        require(delegation.delegateQueue.length == 0, DelegationQueueNotEmpty(delegation.delegateQueue.length));
        delegation.delegateQueue
            .push(DelegationOpDelegate(uint112(initialStake / StakingLayout.BALANCE_COMPACT_PRECISION), sinceEpoch));

        emit ValidatorAdded(validatorAddress, validatorOwner, uint8(status), commissionRate);
    }

    /// @inheritdoc IStaking
    function removeValidator(address account) external virtual override onlyFromGovernance {
        _removeValidator(account);
    }

    function _removeValidatorFromActiveList(address validatorAddress) internal {
        StakingLayout.removeFromActiveList(StakingLayout.stakingStorage(), validatorAddress);
    }

    function _removeValidator(address validatorAddress) internal {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress));
        // check if validator has active delegations
        require(_totalDelegatedToValidator(validator) == 0, ValidatorHasActiveDelegations(validatorAddress));
        // remove validator from active list if exists
        _removeValidatorFromActiveList(validatorAddress);
        // remove from validators map
        delete $._validatorOwners[validator.ownerAddress];
        delete $._validatorsMap[validatorAddress];
        emit ValidatorRemoved(validatorAddress);
    }

    /// @inheritdoc IStaking
    function activateValidator(address validator) external virtual override onlyFromGovernance {
        _activateValidator(validator);
    }

    function _activateValidator(address validatorAddress) internal {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status == ValidatorStatus.Pending, NotPendingValidator(validatorAddress));
        $._activeValidatorsList.push(validatorAddress);
        validator.status = ValidatorStatus.Active;
        // Persist after touching the snapshot because the call may advance `validator.changedAt`.
        ValidatorSnapshot storage snapshot = StakingLayout.touchValidatorSnapshot($, validator, _nextEpoch());
        $._validatorsMap[validatorAddress] = validator;

        emit ValidatorModified(
            validatorAddress, validator.ownerAddress, uint8(validator.status), snapshot.commissionRate
        );
    }

    /// @inheritdoc IStaking
    function disableValidator(address validator) external virtual override onlyFromGovernance {
        _disableValidator(validator);
    }

    function _disableValidator(address validatorAddress) internal {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status == ValidatorStatus.Active, NotActiveValidator());
        _removeValidatorFromActiveList(validatorAddress);
        validator.status = ValidatorStatus.Pending;
        // Persist after touching the snapshot because the call may advance `validator.changedAt`.
        ValidatorSnapshot storage snapshot = StakingLayout.touchValidatorSnapshot($, validator, _nextEpoch());
        $._validatorsMap[validatorAddress] = validator;

        emit ValidatorModified(
            validatorAddress, validator.ownerAddress, uint8(validator.status), snapshot.commissionRate
        );
    }

    /// @inheritdoc IStaking
    function changeValidatorCommissionRate(address validatorAddress, uint16 commissionRate) external {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        require(
            commissionRate >= COMMISSION_RATE_MIN_VALUE && commissionRate <= COMMISSION_RATE_MAX_VALUE,
            BadCommissionRate(commissionRate)
        );
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress));
        require(validator.ownerAddress == msg.sender, OnlyValidatorOwner(validator.ownerAddress));
        ValidatorSnapshot storage snapshot = StakingLayout.touchValidatorSnapshot($, validator, _nextEpoch());
        snapshot.commissionRate = commissionRate;
        $._validatorsMap[validatorAddress] = validator;

        emit ValidatorModified(
            validator.validatorAddress, validator.ownerAddress, uint8(validator.status), commissionRate
        );
    }

    /// @inheritdoc IStaking
    function changeValidatorOwner(address validatorAddress, address newOwner) external override {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        Validator memory validator = $._validatorsMap[validatorAddress];
        // Reject unknown validators before checking ownership so callers receive the correct error.
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress));
        require(validator.ownerAddress == msg.sender, OnlyValidatorOwner(validator.ownerAddress));
        require(newOwner != address(0), OwnerCantBeZero());
        require($._validatorOwners[newOwner] == address(0x00), ValidatorOwnerAlreadyInUse(validatorAddress));
        delete $._validatorOwners[validator.ownerAddress];
        validator.ownerAddress = newOwner;
        $._validatorOwners[newOwner] = validatorAddress;
        // Persist after touching the snapshot because the call may advance `validator.changedAt`.
        ValidatorSnapshot storage snapshot = StakingLayout.touchValidatorSnapshot($, validator, _nextEpoch());
        $._validatorsMap[validatorAddress] = validator;

        emit ValidatorModified(
            validator.validatorAddress, validator.ownerAddress, uint8(validator.status), snapshot.commissionRate
        );
    }

    /// @inheritdoc IStaking
    function isValidatorActive(address account) external view override returns (bool) {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
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
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        return $._validatorsMap[account].status != ValidatorStatus.NotFound;
    }

    function _getValidators() internal view returns (address[] memory) {
        return StakingLayout.getValidatorsAt(_chainConfigContract, _currentEpoch());
    }

    function getValidators() external view override returns (address[] memory) {
        return _getValidators();
    }

    function deposit(address validatorAddress, uint256 amount)
        external
        virtual
        override
        onlyFromCoinbase
        onlyZeroGasPrice
    {
        _depositFee(validatorAddress, amount);
    }

    function _depositFee(address validatorAddress, uint256 amount) internal {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        require(amount > 0, DepositIsZero());
        // make sure validator is active
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress));
        uint64 epoch = _currentEpoch();
        // increase total pending rewards for validator for current epoch
        ValidatorSnapshot storage currentSnapshot = StakingLayout.touchValidatorSnapshot($, validator, epoch);
        currentSnapshot.totalRewards += uint96(amount);
        // Pull tokens after reward accounting is updated.
        _stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit ValidatorDeposited(validatorAddress, amount, epoch);
    }

    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function getValidatorFee(address validatorAddress) external view override returns (uint256) {
        return StakingEconomics.getValidatorFee(_chainConfigContract, validatorAddress);
    }

    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function getPendingValidatorFee(address validatorAddress) external view override returns (uint256) {
        return StakingEconomics.getPendingValidatorFee(_chainConfigContract, validatorAddress);
    }

    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function claimValidatorFee(address validatorAddress) external override {
        StakingEconomics.claimValidatorFee(_chainConfigContract, _stakingToken, _systemRewardContract, validatorAddress);
    }

    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function claimValidatorFeeAtEpoch(address validatorAddress, uint64 beforeEpoch) external override {
        StakingEconomics.claimValidatorFeeAtEpoch(
            _chainConfigContract, _stakingToken, _systemRewardContract, validatorAddress, beforeEpoch
        );
    }

    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function getDelegatorFee(address validatorAddress, address delegatorAddress)
        external
        view
        override
        returns (uint256)
    {
        return StakingEconomics.getDelegatorFee(_chainConfigContract, validatorAddress, delegatorAddress);
    }

    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function getPendingDelegatorFee(address validatorAddress, address delegatorAddress)
        external
        view
        override
        returns (uint256)
    {
        return StakingEconomics.getPendingDelegatorFee(_chainConfigContract, validatorAddress, delegatorAddress);
    }

    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function claimDelegatorFee(address validatorAddress) external override {
        StakingEconomics.claimDelegatorFee(_chainConfigContract, _stakingToken, validatorAddress);
    }

    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function calcAvailableForRedelegateAmount(address validator, address delegator)
        external
        view
        override
        returns (uint256 amountToStake, uint256 rewardsDust)
    {
        return StakingEconomics.calcAvailableForRedelegateAmount(_chainConfigContract, validator, delegator);
    }

    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function redelegateDelegatorFee(address validator) external override {
        StakingEconomics.redelegateDelegatorFee(_chainConfigContract, _stakingToken, validator);
    }

    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function claimDelegatorFeeAtEpoch(address validatorAddress, uint64 beforeEpoch) external override {
        StakingEconomics.claimDelegatorFeeAtEpoch(_chainConfigContract, _stakingToken, validatorAddress, beforeEpoch);
    }

    /// @notice Slash a validator for sustained liveness misses. Sole caller
    ///         is the `LivenessSlashing` predeploy. Reuses `_slashValidator`.
    function slash(address validatorAddress) external virtual override onlyFromLivenessSlashing {
        _slashValidator(validatorAddress);
    }

    /// @notice Register consensus keys for `validator` with on-chain
    ///         Proof-of-Possession. One-shot — no rotation in v1.
    /// @param blsPubkeyUncompressed 256 B EIP-2537 G2 — compressed on-chain
    ///                              to the stored 96 B identity.
    /// @param blsPoPUncompressed    128 B EIP-2537 G1 PoP signature — verify-only.
    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function setConsensusKeys(
        address validatorAddress,
        bytes calldata blsPubkeyUncompressed,
        bytes calldata blsPoPUncompressed,
        bytes32 peerPubkey
    ) external override {
        StakingDpos.setConsensusKeys(
            _chainConfigContract, validatorAddress, blsPubkeyUncompressed, blsPoPUncompressed, peerPubkey
        );
    }

    function getConsensusKeys(address validatorAddress) external view override returns (IStaking.ConsensusKeys memory) {
        return StakingLayout.consensusKeysStorage().consensusKeys[validatorAddress];
    }

    function getValidatorsWithKeys()
        external
        view
        override
        returns (address[] memory addrs, IStaking.ConsensusKeys[] memory keys)
    {
        addrs = _getValidators();
        keys = new IStaking.ConsensusKeys[](addrs.length);
        StakingLayout.ConsensusKeysStorage storage $ck = StakingLayout.consensusKeysStorage();
        for (uint256 i = 0; i < addrs.length; i++) {
            keys[i] = $ck.consensusKeys[addrs[i]];
        }
    }

    /// @inheritdoc IStaking
    function getRegistryWithKeys()
        external
        view
        override
        returns (address[] memory addrs, IStaking.ConsensusKeys[] memory keys)
    {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        uint256 n = $._activeValidatorsList.length;
        addrs = new address[](n);
        keys = new IStaking.ConsensusKeys[](n);
        StakingLayout.ConsensusKeysStorage storage $ck = StakingLayout.consensusKeysStorage();
        for (uint256 i = 0; i < n; i++) {
            addrs[i] = $._activeValidatorsList[i];
            keys[i] = $ck.consensusKeys[addrs[i]];
        }
    }

    /// @notice Epoch-parameterized variant of getValidatorsWithKeys: the
    ///         stake-weighted keyed top-k set as of `epoch`. The executor uses
    ///         this to derive the committee for a future epoch it is about to
    ///         commit one epoch ahead (see commitEpochCommittee).
    function getValidatorsWithKeysAt(uint64 epoch)
        external
        view
        override
        returns (address[] memory addrs, IStaking.ConsensusKeys[] memory keys)
    {
        addrs = StakingLayout.getValidatorsAt(_chainConfigContract, epoch);
        keys = new IStaking.ConsensusKeys[](addrs.length);
        StakingLayout.ConsensusKeysStorage storage $ck = StakingLayout.consensusKeysStorage();
        for (uint256 i = 0; i < addrs.length; i++) {
            keys[i] = $ck.consensusKeys[addrs[i]];
        }
    }

    /// @notice The next epoch whose committee is not yet committed
    ///         (== lastCommittedEpochP1). The executor reads this to know which
    ///         epoch to derive + commit next in its ahead-of-time catch-up loop.
    function nextEpochToCommit() external view override returns (uint64) {
        return StakingLayout.epochCommitteeStorage().lastCommittedEpochP1;
    }

    /// @notice The epoch whose EffBal selects the next committee to commit:
    ///         `nextEpochToCommit() - 1` (0 at genesis). The executor passes this
    ///         to getValidatorsWithKeysAt so the derived committee matches the
    ///         contract's `_getValidatorsAt(selectionEpoch)` verification.
    function committeeSelectionEpoch() external view override returns (uint64) {
        uint64 target = StakingLayout.epochCommitteeStorage().lastCommittedEpochP1;
        return target == 0 ? 0 : target - 1;
    }

    function _slashValidator(address validatorAddress) internal {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        // make sure validator exists
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress));
        uint64 epoch = _currentEpoch();
        // increase slashes for current epoch
        ValidatorSnapshot storage currentSnapshot = StakingLayout.touchValidatorSnapshot($, validator, epoch);
        uint32 slashesCount = currentSnapshot.slashesCount + 1;
        currentSnapshot.slashesCount = slashesCount;
        // validator state might change, lets update it
        $._validatorsMap[validatorAddress] = validator;
        // Jail once the per-epoch slash count reaches the felony threshold.
        // `>=` not `==`: a governance felonyThreshold cut below an already-higher
        // in-flight count would make `==` skip the jail forever (audit P1).
        if (slashesCount >= _chainConfigContract.getFelonyThreshold()) {
            validator.jailedBefore = _currentEpoch() + _chainConfigContract.getValidatorJailEpochLength();
            validator.status = ValidatorStatus.Jail;
            _removeValidatorFromActiveList(validatorAddress);
            $._validatorsMap[validatorAddress] = validator;
            emit ValidatorJailed(validatorAddress, epoch);
        }

        emit ValidatorSlashed(validatorAddress, slashesCount, epoch);
    }

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
    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function commitEpochCommittee(address[] calldata committee) external virtual override onlySystemCall {
        uint64 cur = _currentEpoch();
        // Commit the NEXT-uncommitted epoch, one epoch ahead. `lastCommittedEpochP1`
        // doubles as "next epoch to commit" (epochs 0..lastCommittedEpochP1-1 are
        // already committed; the genesis sentinel 0 ⇒ commit epoch 0).
        //
        // The gate `target <= cur + 1` is the snapshot-finality guarantee:
        // committee[target] reads snapshot[target-1], whose contributing delegations
        // come from epoch (target-1)-WARMUP_DELAY = target-3; with WARMUP_DELAY=2
        // those are final once cur >= target-1, i.e. target <= cur+1. Fail-loud
        // (revert): the executor's catch-up loop only calls within range, so an
        // out-of-range call is a bug.
        uint64 target = StakingLayout.epochCommitteeStorage().lastCommittedEpochP1;
        if (target > cur + 1) revert EpochNotYetCommittable(target, cur);
        uint64 selectionEpoch = target == 0 ? 0 : target - 1; // EffBal(target-1); cf. committeeSelectionEpoch()
        StakingDpos.commitEpochCommittee(_chainConfigContract, committee, target, cur, selectionEpoch);
    }

    /// @notice Resolves a Simplex signer index for a past epoch to the
    ///         validator address, using that epoch's frozen committee.
    function resolveSigner(uint64 epoch, uint32 signerIdx) external view override returns (address) {
        return _resolveSignerToValidator(epoch, signerIdx);
    }

    function _resolveSignerToValidator(uint64 epoch, uint32 signerIdx) internal view returns (address) {
        address[] storage c = StakingLayout.epochCommitteeStorage().committee[epoch];
        uint256 n = c.length;
        if (n == 0) revert EpochCommitteeNotCommitted(epoch);
        if (signerIdx >= n) revert SignerIndexOutOfRange(epoch, signerIdx, n);
        return c[signerIdx];
    }

    /// @notice Returns the frozen committee for `epoch` (Simplex committee order), or
    ///         empty if never committed. Consumed by fluent-staking-reader.
    function getEpochCommittee(uint64 epoch) external view override returns (address[] memory) {
        return StakingLayout.epochCommitteeStorage().committee[epoch];
    }

    function getEpochCommitteeLength(uint64 epoch) external view override returns (uint256) {
        return StakingLayout.epochCommitteeStorage().committee[epoch].length;
    }

    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function slashEquivocationNotarize(
        bytes calldata evidence,
        bytes calldata pkUncompressed,
        bytes calldata sig1Uncompressed,
        bytes calldata sig2Uncompressed
    ) external override {
        StakingDpos.slashEquivocationNotarize(
            _chainConfigContract, evidence, pkUncompressed, sig1Uncompressed, sig2Uncompressed
        );
    }

    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function slashEquivocationFinalize(
        bytes calldata evidence,
        bytes calldata pkUncompressed,
        bytes calldata sig1Uncompressed,
        bytes calldata sig2Uncompressed
    ) external override {
        StakingDpos.slashEquivocationFinalize(
            _chainConfigContract, evidence, pkUncompressed, sig1Uncompressed, sig2Uncompressed
        );
    }

    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function slashEquivocationNullifyFinalize(
        bytes calldata evidence,
        bytes calldata pkUncompressed,
        bytes calldata sig1Uncompressed,
        bytes calldata sig2Uncompressed
    ) external override {
        StakingDpos.slashEquivocationNullifyFinalize(
            _chainConfigContract, evidence, pkUncompressed, sig1Uncompressed, sig2Uncompressed
        );
    }
}
