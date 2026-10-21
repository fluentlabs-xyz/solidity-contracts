// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {stBlend} from "../../contracts/stBlend/stBlend.sol";
import {RewardPool} from "../../contracts/stBlend/RewardPool.sol";
import {IstBlend, IstBlendErrors} from "../../contracts/interfaces/IstBlend.sol";
import {IRewardPoolErrors, IRewardPoolEvents} from "../../contracts/interfaces/IRewardPool.sol";
import {MockERC20Token} from "../mocks/MockERC20.sol";

contract RewardPoolTest is Test {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 internal constant REWARDS_DISTRIBUTOR_ROLE = keccak256("REWARDS_DISTRIBUTOR_ROLE");

    address internal admin = makeAddr("admin");
    address internal tempDistributor = makeAddr("tempDistributor");
    address internal keeper = makeAddr("keeper");
    address internal funder = makeAddr("funder");
    address internal stranger = makeAddr("stranger");

    MockERC20Token internal asset;
    stBlend internal vault;
    RewardPool internal pool;

    uint64 internal constant STREAM_DURATION = 1 days;
    uint256 internal constant DAILY_REWARD = 100e18;
    uint256 internal constant INITIAL_FUND = 1_000_000e18;

    function setUp() public {
        asset = new MockERC20Token("Fluent", "FLUENT", INITIAL_FUND, address(this));

        stBlend vaultImpl = new stBlend();
        bytes memory vaultInit = abi.encodeCall(
            stBlend.initialize,
            (IERC20(address(asset)), "Staked Fluent", "sFLUENT", admin, admin, tempDistributor, STREAM_DURATION, 0)
        );
        vault = stBlend(address(new ERC1967Proxy(address(vaultImpl), vaultInit)));

        pool = _deployPool(address(vault));

        vm.startPrank(admin);
        vault.grantRole(REWARDS_DISTRIBUTOR_ROLE, address(pool));
        vault.revokeRole(REWARDS_DISTRIBUTOR_ROLE, tempDistributor);
        vm.stopPrank();

        asset.transfer(funder, 500_000e18);
        vm.prank(funder);
        asset.approve(address(pool), type(uint256).max);

        vm.warp(1_700_000_000);
    }

    function _deployPool(address vaultAddr) internal returns (RewardPool) {
        RewardPool impl = new RewardPool();
        return RewardPool(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(RewardPool.initialize, (admin, IstBlend(vaultAddr), DAILY_REWARD, STREAM_DURATION))
                )
            )
        );
    }

    // =========================================================================================
    // Integration — pool → vault daily streaming
    // =========================================================================================

    function test_integration_dailyDistributionStreamsIntoVault() public {
        vm.prank(funder);
        pool.fund(DAILY_REWARD * 3);

        vm.prank(keeper);
        pool.distribute();
        assertEq(vault.rewardRate(), DAILY_REWARD / STREAM_DURATION);
        assertEq(vault.periodFinish(), uint64(block.timestamp) + STREAM_DURATION);

        vm.warp(block.timestamp + STREAM_DURATION / 2);
        assertApproxEqAbs(vault.undistributedRewards(), DAILY_REWARD / 2, STREAM_DURATION);

        vm.warp(block.timestamp + STREAM_DURATION);
        assertEq(vault.undistributedRewards(), 0);

        vm.warp(block.timestamp + 1);
        vm.prank(keeper);
        pool.distribute();
        assertGt(vault.rewardRate(), 0);
    }

    function test_primary_flow_withRewardPool() public {
        uint256 aliceKey = 0xA11CE;
        address alice = vm.addr(aliceKey);

        asset.transfer(alice, 100_000e18);
        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);

        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(funder);
        pool.fund(DAILY_REWARD);

        vm.prank(keeper);
        pool.distribute();

        vm.warp(block.timestamp + STREAM_DURATION);
        assertApproxEqAbs(vault.totalAssets(), 100e18 + DAILY_REWARD, STREAM_DURATION);

        vm.prank(alice);
        uint256 redeemed = vault.redeem(100e18, alice, alice);
        assertApproxEqAbs(redeemed, 100e18 + DAILY_REWARD, STREAM_DURATION);
    }

    // =========================================================================================
    // Initialization
    // =========================================================================================

    function test_initialize_grantsRolesAndStoresConfig() public view {
        assertTrue(pool.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(pool.hasRole(UPGRADER_ROLE, admin));
        assertEq(address(pool.vault()), address(vault));
        assertEq(address(pool.rewardToken()), address(asset));
        assertEq(pool.dailyRewardAmount(), DAILY_REWARD);
        assertEq(pool.distributionPeriod(), STREAM_DURATION);
        assertEq(pool.lastDistributionTime(), 0);
    }

    function test_RevertIf_initialize_zeroAdmin() public {
        RewardPool impl = new RewardPool();
        bytes memory data = abi.encodeCall(RewardPool.initialize, (address(0), IstBlend(address(vault)), DAILY_REWARD, STREAM_DURATION));
        vm.expectRevert(abi.encodeWithSelector(IRewardPoolErrors.ZeroAddressNotAllowed.selector, "admin"));
        new ERC1967Proxy(address(impl), data);
    }

    function test_RevertIf_initialize_zeroVault() public {
        RewardPool impl = new RewardPool();
        bytes memory data = abi.encodeCall(RewardPool.initialize, (admin, IstBlend(address(0)), DAILY_REWARD, STREAM_DURATION));
        vm.expectRevert(abi.encodeWithSelector(IRewardPoolErrors.ZeroAddressNotAllowed.selector, "vault"));
        new ERC1967Proxy(address(impl), data);
    }

    function test_RevertIf_initialize_zeroDailyAmount() public {
        RewardPool impl = new RewardPool();
        bytes memory data = abi.encodeCall(RewardPool.initialize, (admin, IstBlend(address(vault)), 0, STREAM_DURATION));
        vm.expectRevert(IRewardPoolErrors.ZeroAmount.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_RevertIf_initialize_periodTooShort() public {
        RewardPool impl = new RewardPool();
        bytes memory data = abi.encodeCall(RewardPool.initialize, (admin, IstBlend(address(vault)), DAILY_REWARD, 1 minutes));
        vm.expectRevert(
            abi.encodeWithSelector(
                IRewardPoolErrors.InvalidDistributionPeriod.selector,
                1 minutes,
                pool.MIN_DISTRIBUTION_PERIOD(),
                pool.MAX_DISTRIBUTION_PERIOD()
            )
        );
        new ERC1967Proxy(address(impl), data);
    }

    function test_RevertIf_initializeTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        pool.initialize(admin, IstBlend(address(vault)), DAILY_REWARD, STREAM_DURATION);
    }

    // =========================================================================================
    // fund
    // =========================================================================================

    function test_fund_increasesBalance() public {
        vm.expectEmit(true, false, false, true, address(pool));
        emit IRewardPoolEvents.Funded(funder, DAILY_REWARD);
        vm.prank(funder);
        pool.fund(DAILY_REWARD);
        assertEq(asset.balanceOf(address(pool)), DAILY_REWARD);
    }

    function test_RevertIf_fund_zeroAmount() public {
        vm.prank(funder);
        vm.expectRevert(IRewardPoolErrors.ZeroAmount.selector);
        pool.fund(0);
    }

    // =========================================================================================
    // distribute
    // =========================================================================================

    function test_distribute_pushesRewardsToVault() public {
        vm.prank(funder);
        pool.fund(DAILY_REWARD);

        vm.expectEmit(true, false, false, true, address(pool));
        emit IRewardPoolEvents.RewardsDistributed(keeper, DAILY_REWARD, uint64(block.timestamp) + STREAM_DURATION);
        vm.prank(keeper);
        pool.distribute();

        assertEq(asset.balanceOf(address(vault)), DAILY_REWARD);
        assertEq(pool.lastDistributionTime(), uint64(block.timestamp));
    }

    function test_RevertIf_distribute_tooEarly() public {
        vm.prank(funder);
        pool.fund(DAILY_REWARD * 2);

        vm.prank(keeper);
        pool.distribute();

        uint64 nextAllowed = uint64(block.timestamp) + STREAM_DURATION;
        vm.expectRevert(abi.encodeWithSelector(IRewardPoolErrors.DistributionTooEarly.selector, nextAllowed));
        vm.prank(keeper);
        pool.distribute();
    }

    function test_RevertIf_distribute_insufficientBalance() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IRewardPoolErrors.InsufficientBalance.selector, DAILY_REWARD, 0));
        pool.distribute();
    }

    function test_RevertIf_distribute_notDistributorOnVault() public {
        RewardPool roguePool = _deployPool(address(vault));
        vm.prank(funder);
        asset.approve(address(roguePool), type(uint256).max);
        vm.prank(funder);
        roguePool.fund(DAILY_REWARD);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(roguePool),
                REWARDS_DISTRIBUTOR_ROLE
            )
        );
        roguePool.distribute();
    }

    function test_RevertIf_distribute_rateWouldBeZero() public {
        vm.prank(admin);
        pool.setDailyRewardAmount(STREAM_DURATION - 1);

        vm.prank(funder);
        pool.fund(STREAM_DURATION - 1);

        vm.prank(keeper);
        vm.expectRevert(IstBlendErrors.RewardRateZero.selector);
        pool.distribute();
    }

    // =========================================================================================
    // Admin
    // =========================================================================================

    function test_setDailyRewardAmount_updatesConfig() public {
        vm.expectEmit(true, true, true, true, address(pool));
        emit IRewardPoolEvents.DailyRewardAmountUpdated(DAILY_REWARD, 200e18);
        vm.prank(admin);
        pool.setDailyRewardAmount(200e18);
        assertEq(pool.dailyRewardAmount(), 200e18);
    }

    function test_setDistributionPeriod_updatesConfig() public {
        vm.expectEmit(true, true, true, true, address(pool));
        emit IRewardPoolEvents.DistributionPeriodUpdated(STREAM_DURATION, 2 days);
        vm.prank(admin);
        pool.setDistributionPeriod(2 days);
        assertEq(pool.distributionPeriod(), 2 days);
    }

    function test_recoverRewards_transfersToRecipient() public {
        vm.prank(funder);
        pool.fund(DAILY_REWARD);

        vm.prank(admin);
        pool.recoverRewards(DAILY_REWARD / 2, admin);
        assertEq(asset.balanceOf(admin), DAILY_REWARD / 2);
        assertEq(asset.balanceOf(address(pool)), DAILY_REWARD / 2);
    }

    function test_RevertIf_setDailyRewardAmount_notAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE)
        );
        pool.setDailyRewardAmount(1);
    }

    function test_RevertIf_recoverRewards_zeroTo() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRewardPoolErrors.ZeroAddressNotAllowed.selector, "to"));
        pool.recoverRewards(1, address(0));
    }

    // =========================================================================================
    // Upgrade
    // =========================================================================================

    function test_upgradeTo_byUpgrader() public {
        RewardPool next = new RewardPool();
        vm.prank(admin);
        pool.upgradeToAndCall(address(next), "");
        assertTrue(pool.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }
}
