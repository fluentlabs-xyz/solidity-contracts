// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

interface ISystemRewardEvents {
    event DistributionShareChanged(address account, uint16 share);
    event FeeClaimed(address account, uint256 nativeAmount, uint256 tokenAmount);
}

/// @title System reward interface
/// @notice Receives system fees and distributes them across governance-configured accounts.
interface ISystemReward is ISystemRewardEvents {
    /// @notice One fee recipient and its share in basis-point-style units.
    struct DistributionShare {
        address account;
        uint16 share;
    }

    /// @notice Replaces fee distribution recipients and shares. Total share must equal 10000.
    function updateDistributionShare(address[] calldata accounts, uint16[] calldata shares) external;

    /// @notice Returns undistributed staking-token system fee balance held by the contract.
    function getSystemFee() external view returns (uint256);

    /// @notice Returns undistributed native ETH system fee balance held by the contract.
    function getNativeSystemFee() external view returns (uint256);

    /// @notice Deposits staking-token system fees for later distribution.
    function deposit(uint256 amount) external;

    /// @notice Distributes currently accumulated native ETH and staking-token system fees when above the minimum threshold.
    function claimSystemFee() external;
}
