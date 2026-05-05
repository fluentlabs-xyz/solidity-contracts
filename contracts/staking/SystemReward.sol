// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./StakingContext.sol";

/// @title System fee distributor
/// @notice Accumulates system fees and distributes them to configured recipients by share.
/// @dev Governance must configure shares so they sum to `SHARE_MAX_VALUE`.
contract SystemReward is ISystemReward, StakingContext {
    bytes32 private constant SYSTEM_REWARD_STORAGE_LOCATION =
        0x85de466a486fac3ceb8a96c8f08f407e42a5512799e7ca6bc110e97735605700;

    /**
     * Parlia has 100 ether limit for max fee, its better to enable auto claim
     * for the system treasury otherwise it might cause lost of funds
     */
    uint256 public constant TREASURY_AUTO_CLAIM_THRESHOLD = 50 ether;
    uint256 public constant TREASURY_MIN_CLAIM_THRESHOLD = 10 wei;
    /**
     * Here is min/max share values.
     *
     * Here is some examples:
     * + 0.3% => 0.3*100=30
     * + 3% => 3*100=300
     * + 30% => 30*100=3000
     */
    uint16 internal constant SHARE_MIN_VALUE = 0; // 0%
    uint16 internal constant SHARE_MAX_VALUE = 10000; // 100%

    event DistributionShareChanged(address account, uint16 share);
    event FeeClaimed(address account, uint256 amount);

    /// @notice One fee recipient and its share in basis-point-style units.
    struct DistributionShare {
        address account;
        uint16 share;
    }

    /// @custom:storage-location erc7201:Fluent.storage.SystemRewardStorage
    struct SystemRewardStorage {
        // total system fee that is available for claim for system needs
        address systemTreasury;
        uint256 systemFee;
        // distribution share between holders
        DistributionShare[] distributionShares;
    }

    function _getSystemRewardStorage() internal pure returns (SystemRewardStorage storage $) {
        assembly {
            $.slot := SYSTEM_REWARD_STORAGE_LOCATION
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

    function initialize(address initialOwner, address[] calldata accounts, uint16[] calldata shares)
        external
        initializer
    {
        __StakingContext_init(initialOwner);
        _updateDistributionShare(accounts, shares);
    }

    function getDistributionShares() external view returns (DistributionShare[] memory) {
        return _getSystemRewardStorage().distributionShares;
    }

    function _updateDistributionShare(address[] calldata accounts, uint16[] calldata shares) internal {
        if (accounts.length != shares.length) revert BadLength();
        SystemRewardStorage storage $ = _getSystemRewardStorage();
        // force claim system fee before changing distribution share
        _claimSystemFee();
        uint16 totalShares = 0;
        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];
            uint16 share = shares[i];
            if (share < SHARE_MIN_VALUE || share > SHARE_MAX_VALUE) revert BadShareDistribution();
            if (i >= $.distributionShares.length) {
                $.distributionShares.push(DistributionShare(account, share));
            } else {
                $.distributionShares[i] = DistributionShare(account, share);
            }
            emit DistributionShareChanged(account, share);
            totalShares += share;
        }
        if (totalShares != SHARE_MAX_VALUE) revert BadShareDistribution();
        while ($.distributionShares.length > accounts.length) {
            $.distributionShares.pop();
        }
    }

    function updateDistributionShare(address[] calldata accounts, uint16[] calldata shares)
        external
        virtual
        override
        onlyFromGovernance
    {
        _updateDistributionShare(accounts, shares);
    }

    function getSystemFee() external view override returns (uint256) {
        return _getSystemRewardStorage().systemFee;
    }

    function claimSystemFee() external override {
        _claimSystemFee();
    }

    receive() external payable {
        SystemRewardStorage storage $ = _getSystemRewardStorage();
        // increase total system fee
        $.systemFee += msg.value;
        // once max fee threshold is reached lets do force claim
        if ($.systemFee >= TREASURY_AUTO_CLAIM_THRESHOLD) {
            _claimSystemFee();
        }
    }

    function _claimSystemFee() internal {
        SystemRewardStorage storage $ = _getSystemRewardStorage();
        uint256 amountToPay = $.systemFee;
        if (amountToPay <= TREASURY_MIN_CLAIM_THRESHOLD) {
            return;
        }
        $.systemFee = 0;
        // if we have system treasury then its legacy scheme
        if ($.systemTreasury != address(0x00)) {
            address payable payableTreasury = payable($.systemTreasury);
            payableTreasury.transfer(amountToPay);
            emit FeeClaimed($.systemTreasury, amountToPay);
            return;
        }
        // distribute rewards based on the shares
        uint256 totalPaid = 0;
        for (uint256 i = 0; i < $.distributionShares.length; i++) {
            DistributionShare memory ds = $.distributionShares[i];
            uint256 accountFee = amountToPay * ds.share / SHARE_MAX_VALUE;
            payable(ds.account).transfer(accountFee);
            emit FeeClaimed(ds.account, accountFee);
            totalPaid += accountFee;
        }
        // return some dust back to the acc
        $.systemFee = amountToPay - totalPaid;
    }
}
