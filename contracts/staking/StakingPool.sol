// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./interfaces/IStaking.sol";
import "./interfaces/IStakingPool.sol";

import "./StakingContext.sol";
import "./Staking.sol";

/// @title Share-based pooled staking
/// @notice Lets users pool ETH per validator while the pool handles delegation, reward claiming, and unstake finalization.
/// @dev Pool shares represent a proportional claim on validator-specific delegated stake plus compounded rewards.
contract StakingPool is StakingContext, IStakingPool {
    bytes32 private constant STAKING_POOL_STORAGE_LOCATION =
        0x3ec11625092490bee5ebf7f2a26d6921811c497aeda967af2d28f1c0388b4a00;

    /**
     * This value must the same as in Staking smart contract
     */
    uint256 internal constant BALANCE_COMPACT_PRECISION = 1e10;

    event Stake(address indexed validator, address indexed staker, uint256 amount);
    event Unstake(address indexed validator, address indexed staker, uint256 amount);
    event Claim(address indexed validator, address indexed staker, uint256 amount);

    /// @notice Accounting state for one validator pool.
    struct ValidatorPool {
        address validatorAddress;
        uint256 sharesSupply;
        uint256 totalStakedAmount;
        uint256 dustRewards;
        uint256 pendingUnstake;
    }

    /// @notice One outstanding unstake request for a staker and validator.
    struct PendingUnstake {
        uint256 amount;
        uint256 shares;
        uint64 epoch;
    }

    /// @custom:storage-location erc7201:Fluent.storage.StakingPoolStorage
    struct StakingPoolStorage {
        // validator pools (validator => pool)
        mapping(address => ValidatorPool) validatorPools;
        // pending undelegates (validator => staker => pending unstake)
        mapping(address => mapping(address => PendingUnstake)) pendingUnstakes;
        // allocated shares (validator => staker => shares)
        mapping(address => mapping(address => uint256)) stakerShares;
    }

    function _getStakingPoolStorage() private pure returns (StakingPoolStorage storage $) {
        assembly {
            $.slot := STAKING_POOL_STORAGE_LOCATION
        }
    }

    constructor(
        IStaking stakingContract,
        ISlashingIndicator slashingIndicatorContract,
        ISystemReward systemRewardContract,
        IStakingPool stakingPoolContract,
        IGovernance governanceContract,
        IChainConfig chainConfigContract
    )
        StakingContext(
            stakingContract,
            slashingIndicatorContract,
            systemRewardContract,
            stakingPoolContract,
            governanceContract,
            chainConfigContract
        )
    {}

    function initialize(address initialOwner) external initializer {
        __StakingContext_init(initialOwner);
    }

    function getStakedAmount(address validator, address staker) external view returns (uint256) {
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        return _getStakingPoolStorage().stakerShares[validator][staker] * 1e18 / _calcRatio(validatorPool);
    }

    function getShares(address validator, address staker) external view returns (uint256) {
        return _getStakingPoolStorage().stakerShares[validator][staker];
    }

    function getValidatorPool(address validator) external view returns (ValidatorPool memory) {
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        (uint256 stakedAmount, uint256 dustRewards) = _calcUnclaimedDelegatorFee(validatorPool);
        validatorPool.totalStakedAmount += stakedAmount;
        validatorPool.dustRewards = dustRewards;
        return validatorPool;
    }

    function getRatio(address validator) external view returns (uint256) {
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        return _calcRatio(validatorPool);
    }

    modifier advanceStakingRewards(address validator) {
        {
            ValidatorPool memory validatorPool = _getValidatorPool(validator);
            // claim rewards from staking contract
            (uint256 stakedAmount, uint256 dustRewards) = _calcUnclaimedDelegatorFee(validatorPool);
            _stakingContract.claimDelegatorFee(validator);
            // re-delegate just arrived rewards
            if (stakedAmount > 0) {
                _stakingContract.delegate{value: stakedAmount}(validator);
            }
            // increase total accumulated rewards
            validatorPool.totalStakedAmount += stakedAmount;
            validatorPool.dustRewards = dustRewards;
            // save validator pool changes
            _getStakingPoolStorage().validatorPools[validator] = validatorPool;
        }
        _;
    }

    function _getValidatorPool(address validator) internal view returns (ValidatorPool memory) {
        ValidatorPool memory validatorPool = _getStakingPoolStorage().validatorPools[validator];
        validatorPool.validatorAddress = validator;
        return validatorPool;
    }

    function _calcUnclaimedDelegatorFee(ValidatorPool memory validatorPool)
        internal
        view
        returns (uint256 stakedAmount, uint256 dustRewards)
    {
        uint256 unclaimedRewards = _stakingContract.getDelegatorFee(validatorPool.validatorAddress, address(this));
        // adjust values based on total dust and pending unstakes
        unclaimedRewards += validatorPool.dustRewards;
        unclaimedRewards -= validatorPool.pendingUnstake;
        // split balance into stake and dust
        stakedAmount = (unclaimedRewards / BALANCE_COMPACT_PRECISION) * BALANCE_COMPACT_PRECISION;
        if (stakedAmount < _chainConfigContract.getMinStakingAmount()) {
            return (0, unclaimedRewards);
        }
        return (stakedAmount, unclaimedRewards - stakedAmount);
    }

    function _calcRatio(ValidatorPool memory validatorPool) internal view returns (uint256) {
        (
            uint256 stakedAmount, /*uint256 dustRewards*/
        ) = _calcUnclaimedDelegatorFee(validatorPool);
        uint256 stakeWithRewards = validatorPool.totalStakedAmount + stakedAmount;
        if (stakeWithRewards == 0) {
            return 1e18;
        }
        return (validatorPool.sharesSupply * 1e18 + stakeWithRewards - 1) / stakeWithRewards;
    }

    function stake(address validator) external payable override advanceStakingRewards(validator) {
        StakingPoolStorage storage $ = _getStakingPoolStorage();
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        uint256 shares = msg.value * _calcRatio(validatorPool) / 1e18;
        // increase total accumulated shares for the staker
        $.stakerShares[validator][msg.sender] += shares;
        // increase staking params for ratio calculation
        validatorPool.totalStakedAmount += msg.value;
        validatorPool.sharesSupply += shares;
        // save validator pool
        $.validatorPools[validator] = validatorPool;
        // delegate these tokens to the staking contract
        _stakingContract.delegate{value: msg.value}(validator);
        // emit event
        emit Stake(validator, msg.sender, msg.value);
    }

    function unstake(address validator, uint256 amount) external override advanceStakingRewards(validator) {
        StakingPoolStorage storage $ = _getStakingPoolStorage();
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        if (validatorPool.totalStakedAmount == 0) revert NothingToUnstake();
        // make sure user doesn't have pending undelegates (we don't support it here)
        if ($.pendingUnstakes[validator][msg.sender].epoch != 0) revert PendingUndelegate();
        // calculate shares and make sure user have enough balance
        uint256 shares = amount * _calcRatio(validatorPool) / 1e18;
        if (shares > $.stakerShares[validator][msg.sender]) revert NotEnoughShares();
        // save new undelegate
        IChainConfig chainConfig = _chainConfigContract;
        $.pendingUnstakes[validator][msg.sender] = PendingUnstake({
            amount: amount, shares: shares, epoch: _stakingContract.nextEpoch() + chainConfig.getUndelegatePeriod()
        });
        validatorPool.pendingUnstake += amount;
        $.validatorPools[validator] = validatorPool;
        // undelegate
        _stakingContract.undelegate(validator, amount);
        // emit event
        emit Unstake(validator, msg.sender, amount);
    }

    function claimableRewards(address validator, address staker) external view override returns (uint256) {
        return _getStakingPoolStorage().pendingUnstakes[validator][staker].amount;
    }

    function claim(address validator) external override advanceStakingRewards(validator) {
        StakingPoolStorage storage $ = _getStakingPoolStorage();
        PendingUnstake memory pendingUnstake = $.pendingUnstakes[validator][msg.sender];
        uint256 amount = pendingUnstake.amount;
        uint256 shares = pendingUnstake.shares;
        // make sure user have pending unstake
        if (pendingUnstake.epoch == 0) revert NothingToClaim();
        if (pendingUnstake.epoch > _stakingContract.currentEpoch()) revert NotReady();
        // updates shares and validator pool params
        $.stakerShares[validator][msg.sender] -= shares;
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        validatorPool.sharesSupply -= shares;
        validatorPool.totalStakedAmount -= amount;
        validatorPool.pendingUnstake -= amount;
        $.validatorPools[validator] = validatorPool;
        // remove pending claim
        delete $.pendingUnstakes[validator][msg.sender];
        // its safe to use call here (state is clear)
        if (address(this).balance < amount) revert NotEnoughBalance();
        payable(address(msg.sender)).transfer(amount);
        // emit event
        emit Claim(validator, msg.sender, amount);
    }

    receive() external payable {
        if (address(msg.sender) != address(_stakingContract)) revert OnlyStakingContract();
    }
}
