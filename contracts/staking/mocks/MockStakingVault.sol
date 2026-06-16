// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockStakingVault
 * @notice Test ERC-4626 vault used by {StakingPool}. Uses fixed 1:1 share math and returns
 *         deposited assets to the caller so the pool can delegate them to the consensus
 *         {Staking} contract in the same transaction.
 */
contract MockStakingVault is ERC4626 {
    using SafeERC20 for IERC20;

    constructor(IERC20 asset_) ERC20("Staked Mock", "sMOCK") ERC4626(asset_) {}

    /// @inheritdoc ERC4626
    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        require(assets != 0, ZeroAssets());
        IERC20 assetToken = IERC20(asset());
        assetToken.safeTransferFrom(msg.sender, address(this), assets);
        shares = assets;
        _mint(receiver, shares);
        assetToken.safeTransfer(msg.sender, assets);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc ERC4626
    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        assets = shares;
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);
        emit Withdraw(msg.sender, receiver, receiver, assets, shares);
    }

    /// @inheritdoc ERC4626
    function convertToShares(uint256 assets) public pure override returns (uint256) {
        return assets;
    }

    /// @inheritdoc ERC4626
    function convertToAssets(uint256 shares) public pure override returns (uint256) {
        return shares;
    }

    /// @inheritdoc ERC4626
    function previewDeposit(uint256 assets) public pure override returns (uint256) {
        return assets;
    }

    /// @inheritdoc ERC4626
    function previewWithdraw(uint256 assets) public pure override returns (uint256) {
        return assets;
    }

    error ZeroAssets();
}
