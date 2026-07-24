// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../Staking.sol";

/// @title Test staking implementation with a reward injector
/// @notice Drop-in {Staking} that preserves ALL production access control (governance
///         gating included) but adds a test-only BLEND reward injector. Reproduces the
///         reserve→settle crediting ledger write (`totalBlendRewards +=` at the current
///         epoch) so reward-accounting tests can exercise the claim math directly.
contract MockStakingRewardInjector is Staking {
    using SafeERC20 for IERC20;

    constructor(
        IStaking stakingContract,
        ISystemReward systemRewardContract,
        IStakingPool stakingPoolContract,
        IFluentGovernance governanceContract,
        IChainConfig chainConfigContract,
        IERC20 stakingToken,
        address livenessSlashingAddr,
        address blendReserveAddr
    )
        Staking(
            stakingContract,
            systemRewardContract,
            stakingPoolContract,
            governanceContract,
            chainConfigContract,
            stakingToken,
            livenessSlashingAddr,
            blendReserveAddr
        )
    {}

    /// @notice Inject a BLEND reward for `validatorAddress` at the current epoch. Writes
    ///         `totalBlendRewards` and pulls the matching BLEND into the contract so the claim
    ///         leg has funds to pay.
    function injectReward(address validatorAddress, uint256 amount) external {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        require(amount > 0, DepositIsZero());
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress));
        uint64 epoch = _currentEpoch();
        ValidatorSnapshot storage currentSnapshot = StakingLayout.touchValidatorSnapshot($, validator, epoch);
        currentSnapshot.totalBlendRewards += uint96(amount);
        _stakingToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Credit a BLEND reward for `validatorAddress` at an ARBITRARY PAST `epoch` via the exact
    ///         at-or-before path `_creditEpoch` uses, so the F1-drain regression exercises the real
    ///         Fix-A helper (a past-epoch credit with `changedAt` already advanced past `epoch`).
    function injectRewardAtEpoch(address validatorAddress, uint256 amount, uint64 epoch) external {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        require(amount > 0, DepositIsZero());
        Validator memory validator = $._validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, ValidatorNotFound(validatorAddress));
        StakingLayout.touchSnapshotAtOrBefore($, validator, epoch).totalBlendRewards += uint96(amount);
        $._validatorsMap[validatorAddress] = validator;
        _stakingToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Raw `snapshot[epoch].totalDelegated` (full-precision wei) — the per-delegator claim
    ///         denominator, exposed so the F1 regression can assert the true-at-epoch stake directly.
    function snapshotTotalDelegated(address validatorAddress, uint64 epoch) external view returns (uint256) {
        return uint256(StakingLayout.stakingStorage()._validatorSnapshots[validatorAddress][epoch].totalDelegated)
            * StakingLayout.BALANCE_COMPACT_PRECISION;
    }
}
