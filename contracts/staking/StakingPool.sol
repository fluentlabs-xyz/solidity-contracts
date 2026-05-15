// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IStaking} from "./interfaces/IStaking.sol";
import {IStakingPool} from "./interfaces/IStakingPool.sol";
import {ISlashingIndicator} from "./interfaces/ISlashingIndicator.sol";
import {ISystemReward} from "./interfaces/ISystemReward.sol";
import {IFluentGovernance} from "./interfaces/IFluentGovernance.sol";
import {IChainConfig} from "./interfaces/IChainConfig.sol";

import {StakingContext} from "./StakingContext.sol";

/**
 * @title Share-based pooled staking
 * @author Fluent Labs
 * @notice Lets users pool the staking ERC20 per validator while the pool handles delegation, reward claiming, and unstake finalization.
 * @dev Pool shares represent a proportional claim on validator-specific delegated stake plus compounded rewards.
 */
contract StakingPool is StakingContext, IStakingPool {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /**
     * @notice This value must the same as in Staking smart contract.
     */
    uint256 internal constant BALANCE_COMPACT_PRECISION = 1e10;

    uint256 internal constant VIRTUAL_ASSETS = 1e3;
    uint256 internal constant VIRTUAL_SHARES = 1e3;

    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.StakingPoolStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STAKING_POOL_STORAGE_LOCATION = 0x3ec11625092490bee5ebf7f2a26d6921811c497aeda967af2d28f1c0388b4a00;

    // ============ Storage ============

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

    function initialize(address initialOwner) external initializer {
        __StakingContext_init(initialOwner);
    }

    function getStakedAmount(address validator, address staker) external view returns (uint256) {
        StakingPoolStorage storage $ = _getStakingPoolStorage();
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        return _convertToAssets($.stakerShares[validator][staker], validatorPool, Math.Rounding.Floor);
    }

    function getShares(address validator, address staker) external view returns (uint256) {
        StakingPoolStorage storage $ = _getStakingPoolStorage();
        return $.stakerShares[validator][staker];
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
        StakingPoolStorage storage $ = _getStakingPoolStorage();
        {
            ValidatorPool memory validatorPool = _getValidatorPool(validator);
            if (validatorPool.pendingUnstake == 0) {
                uint256 balanceBefore = _stakingToken.balanceOf(address(this));
                _stakingContract.claimDelegatorFee(validator);
                uint256 claimedAmount = _stakingToken.balanceOf(address(this)) - balanceBefore;
                _advanceValidatorPoolRewards(validatorPool, claimedAmount);
                $.validatorPools[validator] = validatorPool;
            }
        }
        _;
    }

    function _getValidatorPool(address validator) internal view returns (ValidatorPool memory) {
        StakingPoolStorage storage $ = _getStakingPoolStorage();
        ValidatorPool memory validatorPool = $.validatorPools[validator];
        validatorPool.validatorAddress = validator;
        return validatorPool;
    }

    function _calcUnclaimedDelegatorFee(ValidatorPool memory validatorPool) internal view returns (uint256 stakedAmount, uint256 dustRewards) {
        if (validatorPool.pendingUnstake > 0) {
            return (0, validatorPool.dustRewards);
        }
        uint256 unclaimedRewards = _stakingContract.getDelegatorFee(validatorPool.validatorAddress, address(this));
        return _calcCompoundableDelegatorFee(validatorPool, unclaimedRewards);
    }

    function _calcCompoundableDelegatorFee(
        ValidatorPool memory validatorPool,
        uint256 claimedOrClaimableAmount
    ) internal view returns (uint256 stakedAmount, uint256 dustRewards) {
        uint256 unclaimedRewards = claimedOrClaimableAmount + validatorPool.dustRewards;
        // Pending user claims fully reserve what we just claimed: nothing to compound this
        // cycle. Keep dust rolling forward so it can combine with future rewards instead of
        // underflowing the subtraction below and DoS-ing every pool operation while any
        // user has an outstanding unstake.
        if (validatorPool.pendingUnstake >= unclaimedRewards) {
            return (0, unclaimedRewards);
        }
        unclaimedRewards -= validatorPool.pendingUnstake;
        // split balance into stake and dust
        stakedAmount = (unclaimedRewards / BALANCE_COMPACT_PRECISION) * BALANCE_COMPACT_PRECISION;
        if (stakedAmount < _chainConfigContract.getMinStakingAmount()) {
            return (0, unclaimedRewards);
        }
        return (stakedAmount, unclaimedRewards - stakedAmount);
    }

    function stake(address validator, uint256 amount) external override advanceStakingRewards(validator) {
        StakingPoolStorage storage $ = _getStakingPoolStorage();
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        uint256 shares = _convertToShares(amount, validatorPool, Math.Rounding.Floor);
        _stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        // increase total accumulated shares for the staker
        $.stakerShares[validator][msg.sender] += shares;
        // increase staking params for ratio calculation
        validatorPool.totalStakedAmount += amount;
        validatorPool.sharesSupply += shares;
        // save validator pool
        $.validatorPools[validator] = validatorPool;
        // delegate these tokens to the staking contract
        _approveStaking(amount);
        _stakingContract.delegate(validator, amount);
        // emit event
        emit Staked(validator, msg.sender, amount);
    }

    function unstake(address validator, uint256 amount) external override advanceStakingRewards(validator) {
        StakingPoolStorage storage $ = _getStakingPoolStorage();
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        require(validatorPool.totalStakedAmount > 0, NothingToUnstake());
        // make sure user doesn't have pending undelegates (we don't support it here)
        require($.pendingUnstakes[validator][msg.sender].epoch == 0, PendingUndelegate());
        // calculate shares and make sure user have enough balance
        uint256 shares = _convertToShares(amount, validatorPool, Math.Rounding.Ceil);
        require(shares <= $.stakerShares[validator][msg.sender], NotEnoughShares($.stakerShares[validator][msg.sender]));
        // save new undelegate
        IChainConfig chainConfig = _chainConfigContract;
        $.pendingUnstakes[validator][msg.sender] = PendingUnstake({
            amount: amount,
            shares: shares,
            epoch: _stakingContract.nextEpoch() + chainConfig.getUndelegatePeriod()
        });
        validatorPool.pendingUnstake += amount;
        $.validatorPools[validator] = validatorPool;
        // undelegate
        _stakingContract.undelegate(validator, amount);
        // emit event
        emit Unstaked(validator, msg.sender, amount);
    }

    function claimableRewards(address validator, address staker) external view override returns (uint256) {
        StakingPoolStorage storage $ = _getStakingPoolStorage();
        return $.pendingUnstakes[validator][staker].amount;
    }

    function claim(address validator) external override {
        StakingPoolStorage storage $ = _getStakingPoolStorage();
        PendingUnstake memory pendingUnstake = $.pendingUnstakes[validator][msg.sender];
        uint256 amount = pendingUnstake.amount;
        uint256 shares = pendingUnstake.shares;
        // make sure user have pending unstake
        require(pendingUnstake.epoch > 0, NothingToClaim());
        require(pendingUnstake.epoch <= _stakingContract.currentEpoch(), EpochIsNotReady(pendingUnstake.epoch));
        uint256 balanceBefore = _stakingToken.balanceOf(address(this));
        _stakingContract.claimDelegatorFee(validator);
        uint256 claimedAmount = _stakingToken.balanceOf(address(this)) - balanceBefore;
        // updates shares and validator pool params
        $.stakerShares[validator][msg.sender] -= shares;
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        validatorPool.sharesSupply -= shares;
        validatorPool.totalStakedAmount -= amount;
        validatorPool.pendingUnstake -= amount;
        if (claimedAmount > amount) {
            _advanceValidatorPoolRewards(validatorPool, claimedAmount - amount);
        }
        $.validatorPools[validator] = validatorPool;
        // remove pending claim
        delete $.pendingUnstakes[validator][msg.sender];
        _stakingToken.safeTransfer(msg.sender, amount);
        // emit event
        emit RewardsClaimed(validator, msg.sender, amount);
    }

    function _approveStaking(uint256 amount) internal {
        _stakingToken.forceApprove(address(_stakingContract), amount);
    }

    // ============ Internal functions ============

    function _advanceValidatorPoolRewards(ValidatorPool memory validatorPool, uint256 claimedAmount) internal {
        (uint256 stakedAmount, uint256 dustRewards) = _calcCompoundableDelegatorFee(validatorPool, claimedAmount);
        if (stakedAmount > 0) {
            _approveStaking(stakedAmount);
            _stakingContract.delegate(validatorPool.validatorAddress, stakedAmount);
        }
        validatorPool.totalStakedAmount += stakedAmount;
        validatorPool.dustRewards = dustRewards;
    }

    function _calcRatio(ValidatorPool memory validatorPool) internal view returns (uint256) {
        return (validatorPool.sharesSupply + VIRTUAL_SHARES).mulDiv(1e18, _totalAssets(validatorPool) + VIRTUAL_ASSETS, Math.Rounding.Ceil);
    }

    function _totalAssets(ValidatorPool memory validatorPool) internal view returns (uint256) {
        (uint256 stakedAmount,  /*uint256 dustRewards*/) = _calcUnclaimedDelegatorFee(validatorPool);
        return validatorPool.totalStakedAmount + stakedAmount;
    }

    function _convertToShares(uint256 assets, ValidatorPool memory validatorPool, Math.Rounding rounding) internal view returns (uint256) {
        return assets.mulDiv(validatorPool.sharesSupply + VIRTUAL_SHARES, _totalAssets(validatorPool) + VIRTUAL_ASSETS, rounding);
    }

    function _convertToAssets(uint256 shares, ValidatorPool memory validatorPool, Math.Rounding rounding) internal view returns (uint256) {
        return shares.mulDiv(_totalAssets(validatorPool) + VIRTUAL_ASSETS, validatorPool.sharesSupply + VIRTUAL_SHARES, rounding);
    }
}
