// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./IValidatorSet.sol";

/// @title Validator staking interface
/// @notice Manages validators, delegations, validator commission, delegator rewards, undelegation, and slashing.
interface IStaking is IValidatorSet {
    /// @notice Returns the epoch derived from the current block number.
    function currentEpoch() external view returns (uint64);

    /// @notice Returns the next epoch after `currentEpoch()`.
    function nextEpoch() external view returns (uint64);

    /// @notice Returns whether `validator` is currently in the active validator set.
    function isValidatorActive(address validator) external view returns (bool);

    /// @notice Returns whether `validator` is known to the staking contract in any status.
    function isValidator(address validator) external view returns (bool);

    /// @notice Returns current validator metadata and latest accounting snapshot.
    function getValidatorStatus(address validator)
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
        );

    /// @notice Returns validator metadata with accounting materialized at `epoch`.
    function getValidatorStatusAtEpoch(address validator, uint64 epoch)
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
        );

    /// @notice Returns the validator address owned by `owner`, or zero when none is registered.
    function getValidatorByOwner(address owner) external view returns (address);

    /// @notice Registers `validator` with `msg.sender` as owner and an initial self-stake.
    function registerValidator(address validator, uint16 commissionRate) external payable;

    /// @notice Adds a governance-managed validator.
    function addValidator(address validator) external;

    /// @notice Removes a validator from staking.
    function removeValidator(address validator) external;

    /// @notice Activates a known validator.
    function activateValidator(address validator) external;

    /// @notice Disables a validator without deleting its historical state.
    function disableValidator(address validator) external;

    /// @notice Releases a jailed validator once its jail epoch has elapsed.
    function releaseValidatorFromJail(address validator) external;

    /// @notice Updates validator commission rate.
    function changeValidatorCommissionRate(address validator, uint16 commissionRate) external;

    /// @notice Transfers validator ownership to `newOwner`.
    function changeValidatorOwner(address validator, address newOwner) external;

    /// @notice Returns a delegator's latest delegated amount and the epoch it became effective.
    function getValidatorDelegation(address validator, address delegator)
        external
        view
        returns (uint256 delegatedAmount, uint64 atEpoch);

    /// @notice Delegates `msg.value` to `validator`, effective from the next epoch.
    function delegate(address validator) external payable;

    /// @notice Starts undelegation of `amount` from `validator` for `msg.sender`.
    function undelegate(address validator, uint256 amount) external;

    /// @notice Returns validator owner commission currently claimable.
    function getValidatorFee(address validator) external view returns (uint256);

    /// @notice Returns validator owner commission accrued but not yet claimable.
    function getPendingValidatorFee(address validator) external view returns (uint256);

    /// @notice Claims all currently claimable validator owner commission.
    function claimValidatorFee(address validator) external;

    /// @notice Claims validator owner commission accrued before `beforeEpoch`.
    function claimValidatorFeeAtEpoch(address validator, uint64 beforeEpoch) external;

    /// @notice Returns delegator rewards and matured undelegations currently claimable.
    function getDelegatorFee(address validator, address delegator) external view returns (uint256);

    /// @notice Returns delegator rewards accrued but not yet claimable.
    function getPendingDelegatorFee(address validator, address delegator) external view returns (uint256);

    /// @notice Claims all currently claimable delegator rewards and matured undelegations.
    function claimDelegatorFee(address validator) external;

    /// @notice Calculates reward amount that can be compacted and redelegated without precision dust.
    function calcAvailableForRedelegateAmount(address validator, address delegator)
        external
        view
        returns (uint256 delegatedAmount, uint256 dustAmount);

    /// @notice Claims currently claimable delegator rewards and immediately redelegates compactable amount.
    function redelegateDelegatorFee(address validator) external;

    /// @notice Claims delegator rewards and matured undelegations accrued before `beforeEpoch`.
    function claimDelegatorFeeAtEpoch(address validator, uint64 beforeEpoch) external;

    /// @notice Applies a slash to `validator`; callable by the slashing indicator.
    function slash(address validator) external;
}
