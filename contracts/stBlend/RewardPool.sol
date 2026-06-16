// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IstBlend} from "../interfaces/IstBlend.sol";
import {IRewardPool} from "../interfaces/IRewardPool.sol";

/**
 * @title RewardPool
 * @author Fluent Labs
 *
 * @notice Treasury contract that funds a linked {stBlend} vault with daily reward bundles.
 *         The pool holds {REWARDS_DISTRIBUTOR_ROLE} on the vault and calls {notifyRewards}
 *         once per epoch via the permissionless {distribute} entrypoint.
 *
 * @dev    UUPS-upgradeable with ERC-7201 namespaced storage. Reward tokens must match the
 *         vault's underlying asset. Keep {distributionPeriod} aligned with the vault's
 *         {streamDuration} in production deployments.
 */
contract RewardPool is Initializable, UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, IRewardPool {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Role granted to addresses authorised to perform UUPS upgrades.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @inheritdoc IRewardPool
    uint64 public constant MIN_DISTRIBUTION_PERIOD = 1 hours;

    /// @inheritdoc IRewardPool
    uint64 public constant MAX_DISTRIBUTION_PERIOD = 30 days;

    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.RewardPoolStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant REWARD_POOL_STORAGE_LOCATION = 0x77b54dcd419d52e6b28673db2d025822c1c52eb07fec7b39e38ee5e96ee41800;

    // ============ Storage ============

    /// @custom:storage-location erc7201:Fluent.storage.RewardPoolStorage
    struct RewardPoolStorage {
        IstBlend _vault;
        IERC20 _rewardToken;
        uint256 _dailyRewardAmount;
        uint64 _distributionPeriod;
        uint64 _lastDistributionTime;
        /// @dev Reserved for future storage fields.
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256[46] __gap;
    }

    function _getStorage() private pure returns (RewardPoolStorage storage $) {
        assembly ("memory-safe") {
            $.slot := REWARD_POOL_STORAGE_LOCATION
        }
    }

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /**
     * @notice One-shot initialiser for the upgradeable proxy.
     *
     * @param admin_              Holder of {DEFAULT_ADMIN_ROLE}; also receives {UPGRADER_ROLE}.
     * @param vault_              Linked {stBlend} vault. Must already grant this contract
     *                            {REWARDS_DISTRIBUTOR_ROLE} before the first {distribute}.
     * @param dailyRewardAmount_  Reward amount pushed on each {distribute}, in underlying units.
     *                            Must be ≥ the vault's {streamDuration} so the per-second rate
     *                            does not truncate to zero.
     * @param distributionPeriod_ Minimum elapsed time between distributions. Typically matches
     *                            the vault's {streamDuration} (e.g. 1 days).
     */
    function initialize(
        address admin_,
        IstBlend vault_,
        uint256 dailyRewardAmount_,
        uint64 distributionPeriod_
    ) external initializer {
        require(admin_ != address(0), ZeroAddressNotAllowed("admin"));
        require(address(vault_) != address(0), ZeroAddressNotAllowed("vault"));
        require(dailyRewardAmount_ != 0, ZeroAmount());
        require(
            distributionPeriod_ >= MIN_DISTRIBUTION_PERIOD && distributionPeriod_ <= MAX_DISTRIBUTION_PERIOD,
            InvalidDistributionPeriod(distributionPeriod_, MIN_DISTRIBUTION_PERIOD, MAX_DISTRIBUTION_PERIOD)
        );

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        RewardPoolStorage storage $ = _getStorage();
        $._vault = vault_;
        $._rewardToken = IERC20(IERC4626(address(vault_)).asset());
        $._dailyRewardAmount = dailyRewardAmount_;
        $._distributionPeriod = distributionPeriod_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(UPGRADER_ROLE, admin_);
    }

    // ============ Views ============

    /// @inheritdoc IRewardPool
    function vault() external view returns (IstBlend) {
        return _getStorage()._vault;
    }

    /// @inheritdoc IRewardPool
    function rewardToken() external view returns (IERC20) {
        return _getStorage()._rewardToken;
    }

    /// @inheritdoc IRewardPool
    function dailyRewardAmount() external view returns (uint256) {
        return _getStorage()._dailyRewardAmount;
    }

    /// @inheritdoc IRewardPool
    function distributionPeriod() external view returns (uint64) {
        return _getStorage()._distributionPeriod;
    }

    /// @inheritdoc IRewardPool
    function lastDistributionTime() external view returns (uint64) {
        return _getStorage()._lastDistributionTime;
    }

    // ============ Mutators ============

    /// @inheritdoc IRewardPool
    function fund(uint256 amount) external nonReentrant {
        require(amount != 0, ZeroAmount());
        RewardPoolStorage storage $ = _getStorage();
        $._rewardToken.safeTransferFrom(_msgSender(), address(this), amount);
        emit Funded(_msgSender(), amount);
    }

    /// @inheritdoc IRewardPool
    function distribute() external nonReentrant {
        RewardPoolStorage storage $ = _getStorage();

        uint64 last = $._lastDistributionTime;
        if (last != 0) {
            uint64 nextAllowed = last + $._distributionPeriod;
            require(block.timestamp >= nextAllowed, DistributionTooEarly(nextAllowed));
        }

        uint256 amount = $._dailyRewardAmount;
        uint256 available = $._rewardToken.balanceOf(address(this));
        require(available >= amount, InsufficientBalance(amount, available));

        $._rewardToken.forceApprove(address($._vault), amount);
        $._vault.notifyRewards(amount);

        // SAFE: block.timestamp fits in uint64 until year 2554.
        // forge-lint: disable-next-line(unsafe-typecast)
        $._lastDistributionTime = uint64(block.timestamp);

        emit RewardsDistributed(_msgSender(), amount, $._vault.periodFinish());
    }

    /// @inheritdoc IRewardPool
    function setDailyRewardAmount(uint256 newAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newAmount != 0, ZeroAmount());
        RewardPoolStorage storage $ = _getStorage();
        uint256 previous = $._dailyRewardAmount;
        $._dailyRewardAmount = newAmount;
        emit DailyRewardAmountUpdated(previous, newAmount);
    }

    /// @inheritdoc IRewardPool
    function setDistributionPeriod(uint64 newPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            newPeriod >= MIN_DISTRIBUTION_PERIOD && newPeriod <= MAX_DISTRIBUTION_PERIOD,
            InvalidDistributionPeriod(newPeriod, MIN_DISTRIBUTION_PERIOD, MAX_DISTRIBUTION_PERIOD)
        );
        RewardPoolStorage storage $ = _getStorage();
        uint64 previous = $._distributionPeriod;
        $._distributionPeriod = newPeriod;
        emit DistributionPeriodUpdated(previous, newPeriod);
    }

    /// @inheritdoc IRewardPool
    function recoverRewards(uint256 amount, address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(to != address(0), ZeroAddressNotAllowed("to"));
        require(amount != 0, ZeroAmount());
        _getStorage()._rewardToken.safeTransfer(to, amount);
    }

    // ============ Internal ============

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
