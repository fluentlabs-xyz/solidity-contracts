// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

/**
 * @title ISystemRewardEvents
 * @author Fluent Labs
 * @notice Events emitted by the {SystemReward} contract.
 */
interface ISystemRewardEvents {
    /**
     * @notice Emitted when a governance update writes a fee recipient share into the distribution table.
     * @dev One event is emitted per `(account, share)` pair processed during the update.
     */
    event DistributionShareChanged(address account, uint16 share);

    /**
     * @notice Emitted when a fee recipient is paid their share of pending native ETH and staking-token fees.
     */
    event FeeClaimed(address account, uint256 nativeAmount, uint256 tokenAmount);
}

/**
 * @title ISystemReward
 * @author Fluent Labs
 * @notice Receives system fees and distributes them across governance-configured accounts.
 * @dev Native ETH and staking-token balances are distributed independently using the same share
 *      table. Shares are basis-point-style and must sum to 10_000 (= 100%). The contract
 *      auto-claims once a balance crosses an internal threshold to bound the held funds.
 */
interface ISystemReward is ISystemRewardEvents {
    /**
     * @notice One fee recipient and its share in basis-point-style units (10_000 = 100%).
     */
    struct DistributionShare {
        /// @dev Recipient address that receives native ETH and staking-token fees.
        address account;
        /// @dev Recipient share in basis points (max 10_000).
        uint16 share;
    }

    /**
     * @notice Replaces fee distribution recipients and shares.
     * @dev Total share across the new entries must equal 10_000. The contract force-claims any
     *      pending fees using the previous distribution table before applying the update so
     *      recipients are not retroactively affected. Callable only by governance.
     * @param accounts Recipient accounts in the order their shares are assigned.
     * @param shares Per-recipient share in basis points, parallel to `accounts`.
     */
    function updateDistributionShare(address[] calldata accounts, uint16[] calldata shares) external;

    /**
     * @notice Returns the undistributed staking-token system fee balance held by the contract.
     * @return amount Pending staking-token balance available for distribution.
     */
    function getSystemFee() external view returns (uint256 amount);

    /**
     * @notice Returns the undistributed native ETH system fee balance held by the contract.
     * @return amount Pending native ETH balance available for distribution.
     */
    function getNativeSystemFee() external view returns (uint256 amount);

    /**
     * @notice Deposits staking-token system fees into the contract for later distribution.
     * @dev Pulls `amount` from `msg.sender` (prior ERC20 approval required) and auto-claims once
     *      the accumulated staking-token balance crosses the internal auto-claim threshold.
     * @param amount Staking-token amount to deposit.
     */
    function deposit(uint256 amount) external;

    /**
     * @notice Distributes the accumulated native ETH and staking-token system fees to recipients.
     * @dev No-op when both balances are below the minimum claim threshold; otherwise pays each
     *      recipient their share of both balances and emits {ISystemRewardEvents-FeeClaimed} per
     *      recipient.
     */
    function claimSystemFee() external;
}
