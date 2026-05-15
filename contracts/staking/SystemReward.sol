// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {StakingContext} from "./StakingContext.sol";
import {IStaking} from "./interfaces/IStaking.sol";
import {ISlashingIndicator} from "./interfaces/ISlashingIndicator.sol";
import {ISystemReward} from "./interfaces/ISystemReward.sol";
import {IStakingPool} from "./interfaces/IStakingPool.sol";
import {IFluentGovernance} from "./interfaces/IFluentGovernance.sol";
import {IChainConfig} from "./interfaces/IChainConfig.sol";

/// @title System fee distributor
/// @notice Accumulates system fees and distributes them to configured recipients by share.
/// @dev Governance must configure shares so they sum to `SHARE_MAX_VALUE`.
contract SystemReward is ISystemReward, StakingContext {
    using SafeERC20 for IERC20;

    /**
     * Parlia has 100 token limit for max fee, its better to enable auto claim
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

    // keccak256(abi.encode(uint256(keccak256("Fluent.storage.SystemRewardStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SYSTEM_REWARD_STORAGE_LOCATION = 0x85de466a486fac3ceb8a96c8f08f407e42a5512799e7ca6bc110e97735605700;

    /// @custom:storage-location erc7201:Fluent.storage.SystemRewardStorage
    struct SystemRewardStorage {
        // Deprecated in favor of balance-based accounting. Keep this slot to preserve storage layout.
        uint256 systemFee;
        // distribution share between holders
        ISystemReward.DistributionShare[] distributionShares;
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

    function initialize(address initialOwner, address[] calldata accounts, uint16[] calldata shares) external initializer {
        __StakingContext_init(initialOwner);
        _updateDistributionShare(accounts, shares);
    }

    function getDistributionShares() external view returns (DistributionShare[] memory) {
        SystemRewardStorage storage $ = _getSystemRewardStorage();
        return $.distributionShares;
    }

    function _updateDistributionShare(address[] calldata accounts, uint16[] calldata shares) internal {
        require(accounts.length == shares.length, MalformedInputLength());
        SystemRewardStorage storage $ = _getSystemRewardStorage();
        // force claim system fee before changing distribution share
        _claimSystemFee();
        uint16 totalShares = 0;
        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];
            uint16 share = shares[i];
            require(share >= SHARE_MIN_VALUE && share <= SHARE_MAX_VALUE, BadShareDistribution(share));
            if (i >= $.distributionShares.length) {
                $.distributionShares.push(DistributionShare(account, share));
            } else {
                $.distributionShares[i] = DistributionShare(account, share);
            }
            emit DistributionShareChanged(account, share);
            totalShares += share;
        }
        require(totalShares == SHARE_MAX_VALUE, BadShareDistribution(totalShares));
        while ($.distributionShares.length > accounts.length) {
            $.distributionShares.pop();
        }
    }

    function updateDistributionShare(address[] calldata accounts, uint16[] calldata shares) external virtual override onlyFromGovernance {
        _updateDistributionShare(accounts, shares);
    }

    function getSystemFee() external view override returns (uint256) {
        return _stakingToken.balanceOf(address(this));
    }

    function getNativeSystemFee() external view override returns (uint256) {
        return address(this).balance;
    }

    function claimSystemFee() external override {
        _claimSystemFee();
    }

    function deposit(uint256 amount) external override {
        require(amount > 0, DepositIsZero());
        _stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        // once max fee threshold is reached lets do force claim
        if (_stakingToken.balanceOf(address(this)) >= TREASURY_AUTO_CLAIM_THRESHOLD) {
            _claimSystemFee();
        }
    }

    receive() external payable {
        require(msg.value > 0, DepositIsZero());
        // once max fee threshold is reached lets do force claim
        if (address(this).balance >= TREASURY_AUTO_CLAIM_THRESHOLD) {
            _claimSystemFee();
        }
    }

    function _claimSystemFee() internal {
        SystemRewardStorage storage $ = _getSystemRewardStorage();
        uint256 nativeAmountToPay = address(this).balance;
        uint256 tokenAmountToPay = _stakingToken.balanceOf(address(this));
        if (nativeAmountToPay <= TREASURY_MIN_CLAIM_THRESHOLD && tokenAmountToPay <= TREASURY_MIN_CLAIM_THRESHOLD) {
            return;
        }
        // distribute native ETH and staking-token rewards based on the same shares
        for (uint256 i = 0; i < $.distributionShares.length; i++) {
            DistributionShare memory ds = $.distributionShares[i];
            uint256 nativeAccountFee = (nativeAmountToPay * ds.share) / SHARE_MAX_VALUE;
            uint256 tokenAccountFee = (tokenAmountToPay * ds.share) / SHARE_MAX_VALUE;
            if (nativeAccountFee > 0) {
                (bool success, ) = payable(ds.account).call{value: nativeAccountFee}("");
                require(success, UnsafeTransferFailed());
            }
            if (tokenAccountFee > 0) {
                _stakingToken.safeTransfer(ds.account, tokenAccountFee);
            }
            emit FeeClaimed(ds.account, nativeAccountFee, tokenAccountFee);
        }
    }
}
