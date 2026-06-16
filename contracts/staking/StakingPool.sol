// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
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
 * @dev Pool shares are ERC-4626 vault tokens minted at the validator-pool exchange rate. Stakers
 *      must approve the vault share token to this contract before calling {claim}.
 */
contract StakingPool is StakingContext, IStakingPool {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /**
     * @notice ERC-4626 vault whose shares represent a staker's pooled position.
     */
    IERC4626 internal immutable _vault;

    /**
     * @notice This value must the same as in Staking smart contract.
     */
    uint256 internal constant BALANCE_COMPACT_PRECISION = 1e10;

    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.StakingPoolStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STAKING_POOL_STORAGE_LOCATION = 0x3ec11625092490bee5ebf7f2a26d6921811c497aeda967af2d28f1c0388b4a00;

    // ============ Storage ============

    /// @custom:storage-location erc7201:Fluent.storage.StakingPoolStorage
    struct StakingPoolStorage {
        // validator pools (validator => pool)
        mapping(address => ValidatorPool) validatorPools;
        // pending undelegates queue (validator => staker => pending unstakes)
        mapping(address => mapping(address => PendingUnstake[])) pendingUnstakes;
        // first possibly-active pending unstake index (validator => staker => head)
        mapping(address => mapping(address => uint256)) pendingUnstakeHead;
        // shares reserved by active pending unstakes (validator => staker => shares)
        mapping(address => mapping(address => uint256)) pendingUnstakeReservedShares;
        // allocated shares (validator => staker => shares)
        mapping(address => mapping(address => uint256)) stakerShares;
    }

    function _getStakingPoolStorage() private pure returns (StakingPoolStorage storage $) {
        assembly {
            $.slot := STAKING_POOL_STORAGE_LOCATION
        }
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

    constructor(
        IStaking stakingContract,
        ISlashingIndicator slashingIndicatorContract,
        ISystemReward systemRewardContract,
        IStakingPool stakingPoolContract,
        IFluentGovernance governanceContract,
        IChainConfig chainConfigContract,
        IERC20 stakingToken,
        IERC4626 vault
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
    {
        require(address(vault) != address(0), ZeroVault());
        require(vault.asset() == address(stakingToken), VaultAssetMismatch(address(stakingToken), vault.asset()));
        _vault = vault;
    }

    function initialize(address initialOwner) external initializer {
        __StakingContext_init(initialOwner);
    }

    /// @inheritdoc IStakingPool
    function getStakedAmount(address validator, address staker) external view returns (uint256) {
        StakingPoolStorage storage $ = _getStakingPoolStorage();
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        return _convertToAssets($.stakerShares[validator][staker], validatorPool, Math.Rounding.Floor);
    }

    /// @inheritdoc IStakingPool
    function getShares(address validator, address staker) external view returns (uint256) {
        StakingPoolStorage storage $ = _getStakingPoolStorage();
        return $.stakerShares[validator][staker];
    }

    /// @inheritdoc IStakingPool
    function getValidatorPool(address validator) external view returns (ValidatorPool memory) {
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        (uint256 stakedAmount, uint256 dustRewards) = _calcUnclaimedDelegatorFee(validatorPool);
        validatorPool.totalStakedAmount += stakedAmount;
        validatorPool.dustRewards = dustRewards;
        return validatorPool;
    }

    /// @inheritdoc IStakingPool
    function getRatio(address validator) external view returns (uint256) {
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        return _calcRatio(validatorPool);
    }

    /// @inheritdoc IStakingPool
    function getVault() external view returns (address) {
        return address(_vault);
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

    /// @inheritdoc IStakingPool
    function stake(address validator, uint256 amount) external override advanceStakingRewards(validator) {
        StakingPoolStorage storage $ = _getStakingPoolStorage();
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        uint256 shares = _convertToShares(amount, validatorPool, Math.Rounding.Floor);

        _stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        _issueVaultShares(msg.sender, amount, shares);

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

    /// @inheritdoc IStakingPool
    function unstake(address validator, uint256 amount) external override advanceStakingRewards(validator) {
        StakingPoolStorage storage $ = _getStakingPoolStorage();
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        require(validatorPool.totalStakedAmount > 0, NothingToUnstake());
        // Shares are only burned at claim time, so when a staker has other pending unstakes in
        // flight their shares are still on `stakerShares`. We must subtract the shares already
        // committed to earlier unstakes to avoid letting the staker over-commit their balance.
        uint256 shares = _convertToShares(amount, validatorPool, Math.Rounding.Ceil);
        PendingUnstake[] storage queue = $.pendingUnstakes[validator][msg.sender];
        uint256 reservedShares = $.pendingUnstakeReservedShares[validator][msg.sender];
        uint256 availableShares = $.stakerShares[validator][msg.sender] - reservedShares;
        require(shares <= availableShares, NotEnoughShares(availableShares));
        // Append a new pending unstake to the staker's queue. Multiple pending unstakes are
        // supported; each entry matures independently after the undelegate period.
        IChainConfig chainConfig = _chainConfigContract;
        queue.push(PendingUnstake({amount: amount, shares: shares, epoch: _stakingContract.nextEpoch() + chainConfig.getUndelegatePeriod()}));
        $.pendingUnstakeReservedShares[validator][msg.sender] = reservedShares + shares;
        validatorPool.pendingUnstake += amount;
        $.validatorPools[validator] = validatorPool;
        // undelegate
        _stakingContract.undelegate(validator, amount);
        // emit event
        emit Unstaked(validator, msg.sender, amount);
    }

    /// @inheritdoc IStakingPool
    function claimableRewards(address validator, address staker) external view override returns (uint256) {
        StakingPoolStorage storage $ = _getStakingPoolStorage();
        PendingUnstake[] storage queue = $.pendingUnstakes[validator][staker];
        uint64 currentEpoch = _stakingContract.currentEpoch();
        uint256 total;
        uint256 head = $.pendingUnstakeHead[validator][staker];
        uint256 length = queue.length;
        for (uint256 i = head; i < length; ++i) {
            PendingUnstake storage pendingUnstake = queue[i];
            if (pendingUnstake.amount > 0 && pendingUnstake.epoch <= currentEpoch) {
                total += pendingUnstake.amount;
            }
        }
        return total;
    }

    /// @inheritdoc IStakingPool
    function getPendingUnstakes(address validator, address staker) external view override returns (PendingUnstake[] memory) {
        StakingPoolStorage storage $ = _getStakingPoolStorage();
        PendingUnstake[] storage queue = $.pendingUnstakes[validator][staker];
        uint256 head = $.pendingUnstakeHead[validator][staker];
        uint256 length = queue.length;
        uint256 activeCount;
        for (uint256 i = head; i < length; ++i) {
            if (queue[i].amount > 0) {
                ++activeCount;
            }
        }
        PendingUnstake[] memory activeQueue = new PendingUnstake[](activeCount);
        uint256 j;
        for (uint256 i = head; i < length; ++i) {
            PendingUnstake storage pendingUnstake = queue[i];
            if (pendingUnstake.amount > 0) {
                activeQueue[j] = pendingUnstake;
                ++j;
            }
        }
        return activeQueue;
    }

    /// @inheritdoc IStakingPool
    /// @dev Pulls reserved vault shares from `msg.sender`; the caller must have approved this pool
    ///      on the vault ERC-20 beforehand.
    function claim(address validator) external override {
        StakingPoolStorage storage $ = _getStakingPoolStorage();
        PendingUnstake[] storage queue = $.pendingUnstakes[validator][msg.sender];
        uint256 pendingCount = queue.length;
        uint256 head = $.pendingUnstakeHead[validator][msg.sender];
        uint256 reservedShares = $.pendingUnstakeReservedShares[validator][msg.sender];
        require(head < pendingCount && reservedShares > 0, NothingToClaim());

        uint64 currentEpoch = _stakingContract.currentEpoch();
        uint256 totalAmount;
        uint256 totalShares;
        uint64 nextUnreadyEpoch = type(uint64).max;
        for (uint256 i = head; i < pendingCount; ++i) {
            PendingUnstake storage pendingUnstake = queue[i];
            if (pendingUnstake.amount == 0) {
                continue;
            }
            if (pendingUnstake.epoch > currentEpoch) {
                if (pendingUnstake.epoch < nextUnreadyEpoch) {
                    nextUnreadyEpoch = pendingUnstake.epoch;
                }
                continue;
            }
            totalAmount += pendingUnstake.amount;
            totalShares += pendingUnstake.shares;
            delete queue[i];
        }
        require(totalAmount > 0, EpochIsNotReady(nextUnreadyEpoch));

        // Pull matured undelegations and any unclaimed delegator rewards from the staking
        // contract. The staking contract releases undelegations on the same matured-epoch rule,
        // so `claimedAmount - totalAmount` is exactly the slice of compoundable rewards.
        uint256 balanceBefore = _stakingToken.balanceOf(address(this));
        _stakingContract.claimDelegatorFee(validator);
        uint256 claimedAmount = _stakingToken.balanceOf(address(this)) - balanceBefore;

        IERC20(address(_vault)).safeTransferFrom(msg.sender, address(this), totalShares);
        _vault.redeem(totalShares, address(this), address(this));

        $.stakerShares[validator][msg.sender] -= totalShares;
        $.pendingUnstakeReservedShares[validator][msg.sender] = reservedShares - totalShares;
        ValidatorPool memory validatorPool = _getValidatorPool(validator);
        validatorPool.sharesSupply -= totalShares;
        validatorPool.totalStakedAmount -= totalAmount;
        validatorPool.pendingUnstake -= totalAmount;
        if (claimedAmount < totalAmount) {
            uint256 dustConsumed = totalAmount - claimedAmount;
            require(dustConsumed <= validatorPool.dustRewards, NotEnoughBalance());
            validatorPool.dustRewards -= dustConsumed;
        } else if (claimedAmount > totalAmount) {
            _advanceValidatorPoolRewards(validatorPool, claimedAmount - totalAmount);
        }
        $.validatorPools[validator] = validatorPool;

        while (head < pendingCount && queue[head].amount == 0) {
            ++head;
        }
        if (head == pendingCount) {
            delete $.pendingUnstakes[validator][msg.sender];
            delete $.pendingUnstakeHead[validator][msg.sender];
        } else {
            $.pendingUnstakeHead[validator][msg.sender] = head;
        }

        _stakingToken.safeTransfer(msg.sender, totalAmount);
        emit RewardsClaimed(validator, msg.sender, totalAmount);
    }

    function _approveStaking(uint256 amount) internal {
        _stakingToken.forceApprove(address(_stakingContract), amount);
    }

    /**
     * @dev Deposits `assets` into the linked vault, minting exactly `shares` vault tokens to
     *      `receiver`. Any excess minted by the vault (when its spot rate is below the
     *      validator-pool rate) is redeemed back to the pool. Reverts if the vault mints fewer
     *      than `shares` — production vaults must keep pace with pool accounting.
     */
    function _issueVaultShares(address receiver, uint256 assets, uint256 shares) internal {
        _stakingToken.forceApprove(address(_vault), assets);
        uint256 mintedShares = _vault.deposit(assets, address(this));
        if (mintedShares < shares) {
            revert VaultShareShortfall(mintedShares, shares);
        }
        if (mintedShares > shares) {
            _vault.redeem(mintedShares - shares, address(this), address(this));
        }
        if (shares != 0) {
            IERC20(address(_vault)).safeTransfer(receiver, shares);
        }
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
        uint256 totalAssets = _totalAssets(validatorPool);
        // Empty pool: the next deposit will mint shares 1:1 with assets, so the spot ratio is 1.
        if (totalAssets == 0) {
            return 1e18;
        }
        return validatorPool.sharesSupply.mulDiv(1e18, totalAssets, Math.Rounding.Ceil);
    }

    function _totalAssets(ValidatorPool memory validatorPool) internal view returns (uint256) {
        (uint256 stakedAmount,  /*uint256 dustRewards*/) = _calcUnclaimedDelegatorFee(validatorPool);
        return validatorPool.totalStakedAmount + stakedAmount;
    }

    function _convertToShares(uint256 assets, ValidatorPool memory validatorPool, Math.Rounding rounding) internal view returns (uint256) {
        uint256 supply = validatorPool.sharesSupply;
        // First deposit (or first stake after a full exit): bootstrap the ratio by minting shares
        // 1:1 with assets. Direct token transfers cannot inflate `_totalAssets` here because the
        // pool's accounting reads delegation state from the staking contract, so the canonical
        // "first depositor inflation" attack does not apply.
        if (supply == 0) {
            return assets;
        }
        return assets.mulDiv(supply, _totalAssets(validatorPool), rounding);
    }

    function _convertToAssets(uint256 shares, ValidatorPool memory validatorPool, Math.Rounding rounding) internal view returns (uint256) {
        uint256 supply = validatorPool.sharesSupply;
        // Symmetric to `_convertToShares`: with no outstanding shares the pool has no assets to
        // value against, so a hypothetical conversion just round-trips 1:1.
        if (supply == 0) {
            return shares;
        }
        return shares.mulDiv(_totalAssets(validatorPool), supply, rounding);
    }
}
