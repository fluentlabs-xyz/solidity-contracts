// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {StakingContext} from "./StakingContext.sol";
import {IBlendReserve} from "./interfaces/IBlendReserve.sol";
import {IStaking} from "./interfaces/IStaking.sol";
import {ISystemReward} from "./interfaces/ISystemReward.sol";
import {IStakingPool} from "./interfaces/IStakingPool.sol";
import {IFluentGovernance} from "./interfaces/IFluentGovernance.sol";
import {IChainConfig} from "./interfaces/IChainConfig.sol";

/// @title BlendReserve
/// @author Fluent Labs
/// @notice Holds the BLEND allocation (topped up ~monthly by governance) that funds the per-epoch
///         stipend. The single auditable place for the balance-clamp, graceful depletion, kill-switch,
///         and reserve events. Funding is a seeded/transferred BLEND balance, NOT an `initialize` arg
///         (no bootstrap ABI break). Reward emission is reallocation from a finite pool — NEVER a mint.
contract BlendReserve is StakingContext, IBlendReserve {
    using SafeERC20 for IERC20;

    /// @notice Staking predeploy — the sole caller of `disburse` (settlement is folded into Staking).
    address private immutable _stakingAddr;

    /// @custom:storage-location erc7201:Fluent.storage.BlendReserveStorage
    struct BlendReserveStorage {
        // Governance kill-switch: when paused, `disburse` sends nothing (returns 0).
        bool paused;
    }

    // keccak256(abi.encode(uint256(keccak256("Fluent.storage.BlendReserveStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BLEND_RESERVE_STORAGE_LOCATION =
        0x8468397eac005049ae4bf70357082fbdef0cf91dd7a3664ce7f1e251e2e06200;

    event ReserveDisbursed(address indexed to, uint256 sent, uint256 remaining);
    event ReservePausedChanged(bool paused);

    modifier onlyFromStaking() {
        require(msg.sender == _stakingAddr, OnlyStakingContract());
        _;
    }

    constructor(
        IStaking stakingContract,
        ISystemReward systemRewardContract,
        IStakingPool stakingPoolContract,
        IFluentGovernance governanceContract,
        IChainConfig chainConfigContract,
        IERC20 stakingToken,
        address stakingAddr
    )
        StakingContext(
            stakingContract,
            systemRewardContract,
            stakingPoolContract,
            governanceContract,
            chainConfigContract,
            stakingToken
        )
    {
        _stakingAddr = stakingAddr;
    }

    function initialize(address initialOwner) external initializer {
        __StakingContext_init(initialOwner);
    }

    function _getBlendReserveStorage() private pure returns (BlendReserveStorage storage $) {
        assembly {
            $.slot := BLEND_RESERVE_STORAGE_LOCATION
        }
    }

    /// @inheritdoc IBlendReserve
    /// @dev Balance-clamped and best-effort (skip-not-revert) so a token quirk can NEVER wedge the
    ///      executor's settle(). `sent = min(amount, balance)`; empties to 0 gracefully.
    /// @dev F9: returns the NOMINAL `sent` (not a measured received-delta). Safe because BLEND is a
    ///      standard, non-fee-on-transfer, non-rebasing fixed-supply ERC20 — enforced by the deploy-time
    ///      address pin (`DeployStaking._assertFixedSupplyToken`, F5). A fee-on-transfer token would
    ///      deliver less than `sent` and over-credit the ledger; such a token can never be the staking
    ///      token in production, so no balance-delta accounting is added here.
    function disburse(address to, uint256 amount) external override onlyFromStaking returns (uint256 sent) {
        if (_getBlendReserveStorage().paused) return 0;
        IERC20 blend = _stakingToken;
        uint256 bal = blend.balanceOf(address(this));
        sent = amount < bal ? amount : bal;
        if (sent > 0) blend.safeTransfer(to, sent);
        emit ReserveDisbursed(to, sent, bal - sent);
    }

    /// @inheritdoc IBlendReserve
    function reserveBalance() external view override returns (uint256) {
        return _stakingToken.balanceOf(address(this));
    }

    /// @notice Governance kill-switch: pause/unpause stipend disbursement independent of the
    ///         `blendStipendPerEpoch` router param.
    function setPaused(bool paused) external onlyFromGovernance {
        _getBlendReserveStorage().paused = paused;
        emit ReservePausedChanged(paused);
    }

    function isPaused() external view returns (bool) {
        return _getBlendReserveStorage().paused;
    }
}
