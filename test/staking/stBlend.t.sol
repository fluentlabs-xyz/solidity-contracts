// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {stBlend} from "../../contracts/stBlend/stBlend.sol";
import {
    IstBlend,
    IstBlendErrors,
    IstBlendEvents
} from "../../contracts/interfaces/IstBlend.sol";
import {MockERC20Token} from "../mocks/MockERC20.sol";

contract stBlendTest is Test {
    // ============ Roles ============

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 internal constant REWARDS_DISTRIBUTOR_ROLE = keccak256("REWARDS_DISTRIBUTOR_ROLE");

    // ============ Actors ============

    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal pool = makeAddr("rewardsPool");
    address internal relayer = makeAddr("relayer");
    address internal stranger = makeAddr("stranger");

    // Bob is a "regular" actor without a private key.
    address internal bob = makeAddr("bob");

    // Alice has a private key so she can sign EIP-712 messages.
    uint256 internal aliceKey = 0xA11CE;
    address internal alice = vm.addr(aliceKey);

    // ============ System under test ============

    MockERC20Token internal asset;
    stBlend internal vault;

    uint64 internal constant STREAM_DURATION = 1 days;
    uint256 internal constant INITIAL_FUND = 1_000_000e18;

    function setUp() public {
        // Fresh underlying asset with plenty of supply for every actor + the reward pool.
        asset = new MockERC20Token("Fluent", "FLUENT", INITIAL_FUND, address(this));

        stBlend impl = new stBlend();
        bytes memory initData = abi.encodeCall(
            stBlend.initialize,
            (IERC20(address(asset)), "Staked Fluent", "sFLUENT", admin, pauser, pool, STREAM_DURATION, 0)
        );
        vault = stBlend(address(new ERC1967Proxy(address(impl), initData)));

        // Seed actors. Approvals are granted up-front so deposit / mint paths don't have to
        // worry about ERC-20 plumbing in every test.
        asset.transfer(alice, 100_000e18);
        asset.transfer(bob, 100_000e18);
        asset.transfer(pool, 100_000e18);

        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(pool);
        asset.approve(address(vault), type(uint256).max);

        // The vault is deployed at a fixed timestamp; advance past zero to avoid timestamp
        // underflow when computing `periodFinish - block.timestamp` in fresh state.
        vm.warp(1_700_000_000);
    }

    // =========================================================================================
    // primary_flow — REQUIRED happy-path coverage of the vault's headline mechanics
    // =========================================================================================

    /// @notice End-to-end happy path covering deposit, streaming-reward accrual, secondary
    ///         deposit at the appreciated share price, and final redemption / withdrawal.
    function primary_flow() public {
        // --- Alice deposits 100 underlying into an empty vault (1:1 share price). ---
        uint256 aliceAssets = 100e18;
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(aliceAssets, alice);
        assertEq(aliceShares, aliceAssets, "alice should mint 1:1 against an empty vault");
        assertEq(vault.totalAssets(), aliceAssets, "totalAssets after alice deposit");
        assertEq(vault.balanceOf(alice), aliceShares, "alice share balance");

        // --- The Pool notifies a 100-underlying reward bundle to stream over 1 day. ---
        uint256 rewardAmount = 100e18;
        vm.prank(pool);
        vault.notifyRewards(rewardAmount);
        assertEq(vault.periodFinish(), uint64(block.timestamp) + STREAM_DURATION, "periodFinish armed");
        assertGt(vault.rewardRate(), 0, "rate set");
        // The contract holds 200 underlying, but only ~100 is visible to shareholders
        // until the stream releases the residual. The few-thousand-wei slack is the dust
        // from `rate = pool / duration` truncating downwards.
        assertEq(asset.balanceOf(address(vault)), aliceAssets + rewardAmount, "raw underlying balance");
        assertApproxEqAbs(vault.totalAssets(), aliceAssets, STREAM_DURATION, "totalAssets excludes pending stream");

        // --- Mid-window snapshot: roughly half the rewards should have accrued. ---
        vm.warp(block.timestamp + STREAM_DURATION / 2);
        uint256 expectedMidTotal = aliceAssets + rewardAmount / 2;
        // Slack <= streamDuration accommodates the dust carried from the rate truncation.
        assertApproxEqAbs(vault.totalAssets(), expectedMidTotal, STREAM_DURATION, "totalAssets after half window");

        // --- Bob deposits 100 at the appreciated share price: expect ~66.66 shares. ---
        uint256 bobAssets = 100e18;
        vm.prank(bob);
        uint256 bobShares = vault.deposit(bobAssets, bob);
        // expected = 100e18 * (alicedShares + 1) / (totalAssets + 1) ≈ 66.666...e18
        // Allow up to 1 share-wei of slack to absorb both the streaming dust and the
        // ERC-4626 mulDiv rounding.
        assertApproxEqAbs(bobShares, 66_666666666666666666, 1e6, "bob shares at mid-window price");

        // --- Roll past periodFinish: residual + dust is fully released. ---
        vm.warp(block.timestamp + STREAM_DURATION);
        assertEq(vault.undistributedRewards(), 0, "no unstreamed rewards after periodFinish");
        // After the window closes, totalAssets equals the raw balance (200 + 100 = 300).
        assertEq(
            vault.totalAssets(),
            asset.balanceOf(address(vault)),
            "all rewards visible after periodFinish"
        );

        // --- Alice redeems all her shares — should receive original principal + reward share. ---
        uint256 aliceAssetsBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 aliceRedeemed = vault.redeem(aliceShares, alice, alice);
        assertGt(aliceRedeemed, aliceAssets, "alice profited from the reward stream");
        assertEq(asset.balanceOf(alice), aliceAssetsBefore + aliceRedeemed, "alice received underlying");

        // --- Bob withdraws his original principal — share-price-locked, no loss. ---
        uint256 bobMaxAssets = vault.maxWithdraw(bob);
        assertGt(bobMaxAssets, bobAssets, "bob also accrued post-deposit rewards");
        vm.prank(bob);
        uint256 bobBurned = vault.withdraw(bobMaxAssets, bob, bob);
        assertLe(bobBurned, bobShares, "bob's burn matches his share balance");

        // --- Final invariant: vault dust never strands user funds. ---
        // Some wei may remain due to integer division in the share formula.
        assertLt(vault.totalAssets(), 10, "dust residual after full unwind");
    }

    /// @dev Foundry-discoverable wrapper for the canonical happy-path test.
    function test_primary_flow() public {
        primary_flow();
    }

    // =========================================================================================
    // Initialization
    // =========================================================================================

    function test_initialize_grantsRolesAndStoresConfig() public view {
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, admin), "admin role granted");
        assertTrue(vault.hasRole(UPGRADER_ROLE, admin), "upgrader role granted");
        assertTrue(vault.hasRole(PAUSER_ROLE, pauser), "pauser role granted");
        assertTrue(vault.hasRole(REWARDS_DISTRIBUTOR_ROLE, pool), "distributor role granted");
        assertEq(vault.streamDuration(), STREAM_DURATION, "streamDuration init");
        assertEq(vault.maxTotalAssets(), 0, "uncapped by default");
        assertEq(vault.asset(), address(asset), "underlying registered");
        assertEq(vault.name(), "Staked Fluent");
        assertEq(vault.symbol(), "sFLUENT");
    }

    function test_initialize_decimalsMatchUnderlying() public view {
        // ERC4626 returns underlying decimals + offset (0 by default) → 18.
        assertEq(vault.decimals(), 18);
    }

    function test_RevertIf_initialize_zeroAsset() public {
        stBlend impl = new stBlend();
        bytes memory data = abi.encodeCall(
            stBlend.initialize,
            (IERC20(address(0)), "x", "x", admin, pauser, pool, STREAM_DURATION, 0)
        );
        vm.expectRevert(abi.encodeWithSelector(IstBlendErrors.ZeroAddressNotAllowed.selector, "asset"));
        new ERC1967Proxy(address(impl), data);
    }

    function test_RevertIf_initialize_zeroAdmin() public {
        stBlend impl = new stBlend();
        bytes memory data = abi.encodeCall(
            stBlend.initialize,
            (IERC20(address(asset)), "x", "x", address(0), pauser, pool, STREAM_DURATION, 0)
        );
        vm.expectRevert(abi.encodeWithSelector(IstBlendErrors.ZeroAddressNotAllowed.selector, "admin"));
        new ERC1967Proxy(address(impl), data);
    }

    function test_RevertIf_initialize_zeroPauser() public {
        stBlend impl = new stBlend();
        bytes memory data = abi.encodeCall(
            stBlend.initialize,
            (IERC20(address(asset)), "x", "x", admin, address(0), pool, STREAM_DURATION, 0)
        );
        vm.expectRevert(abi.encodeWithSelector(IstBlendErrors.ZeroAddressNotAllowed.selector, "pauser"));
        new ERC1967Proxy(address(impl), data);
    }

    function test_RevertIf_initialize_zeroDistributor() public {
        stBlend impl = new stBlend();
        bytes memory data = abi.encodeCall(
            stBlend.initialize,
            (IERC20(address(asset)), "x", "x", admin, pauser, address(0), STREAM_DURATION, 0)
        );
        vm.expectRevert(abi.encodeWithSelector(IstBlendErrors.ZeroAddressNotAllowed.selector, "rewardsDistributor"));
        new ERC1967Proxy(address(impl), data);
    }

    function test_RevertIf_initialize_streamTooShort() public {
        stBlend impl = new stBlend();
        bytes memory data = abi.encodeCall(
            stBlend.initialize,
            (IERC20(address(asset)), "x", "x", admin, pauser, pool, 1 minutes, 0)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IstBlendErrors.InvalidStreamDuration.selector,
                1 minutes,
                vault.MIN_STREAM_DURATION(),
                vault.MAX_STREAM_DURATION()
            )
        );
        new ERC1967Proxy(address(impl), data);
    }

    function test_RevertIf_initialize_streamTooLong() public {
        stBlend impl = new stBlend();
        uint64 tooLong = vault.MAX_STREAM_DURATION() + 1;
        bytes memory data = abi.encodeCall(
            stBlend.initialize,
            (IERC20(address(asset)), "x", "x", admin, pauser, pool, tooLong, 0)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IstBlendErrors.InvalidStreamDuration.selector,
                tooLong,
                vault.MIN_STREAM_DURATION(),
                vault.MAX_STREAM_DURATION()
            )
        );
        new ERC1967Proxy(address(impl), data);
    }

    function test_RevertIf_initializeTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(IERC20(address(asset)), "x", "x", admin, pauser, pool, STREAM_DURATION, 0);
    }

    function test_RevertIf_initialize_implementationDisabled() public {
        stBlend impl = new stBlend();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(IERC20(address(asset)), "x", "x", admin, pauser, pool, STREAM_DURATION, 0);
    }

    // =========================================================================================
    // ERC-4626 mutators
    // =========================================================================================

    function test_deposit_mintsShares() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(50e18, alice);
        assertEq(shares, 50e18);
        assertEq(vault.balanceOf(alice), 50e18);
        assertEq(vault.totalAssets(), 50e18);
    }

    function test_mint_pullsAssets() public {
        vm.prank(alice);
        uint256 assets = vault.mint(50e18, alice);
        assertEq(assets, 50e18);
        assertEq(vault.balanceOf(alice), 50e18);
    }

    function test_withdraw_burnsShares() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(alice);
        uint256 burned = vault.withdraw(40e18, alice, alice);
        assertEq(burned, 40e18, "1:1 burn pre-rewards");
        assertEq(asset.balanceOf(alice), 100_000e18 - 100e18 + 40e18);
    }

    function test_redeem_returnsAssets() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(alice);
        uint256 redeemed = vault.redeem(40e18, alice, alice);
        assertEq(redeemed, 40e18, "1:1 redeem pre-rewards");
    }

    // =========================================================================================
    // Rewards streaming
    // =========================================================================================

    function test_notifyRewards_storesRateAndPeriodFinish() public {
        // Seed a deposit so totalAssets is non-zero.
        vm.prank(alice);
        vault.deposit(100e18, alice);

        uint256 amount = 86_400; // exactly STREAM_DURATION wei → 1 wei/sec
        vm.expectEmit(true, false, false, false, address(vault));
        emit IstBlendEvents.RewardsNotified(pool, amount, 1, uint64(block.timestamp) + STREAM_DURATION);
        vm.prank(pool);
        vault.notifyRewards(amount);

        assertEq(vault.rewardRate(), 1, "1 wei/sec");
        assertEq(vault.periodFinish(), uint64(block.timestamp) + STREAM_DURATION);
        assertEq(vault.undistributedRewards(), amount, "freshly armed, all pending");
    }

    function test_notifyRewards_carriesResidualForward() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(pool);
        vault.notifyRewards(100e18);

        // Halfway through, top up with another 100. The unstreamed half from the previous
        // window (~50e18) should merge with the fresh 100e18 over a new full window.
        vm.warp(block.timestamp + STREAM_DURATION / 2);
        uint256 unstreamedBefore = vault.undistributedRewards();
        vm.prank(pool);
        vault.notifyRewards(100e18);

        // New rate ≈ (50e18 + 100e18) / 86400.
        uint256 expectedRate = (unstreamedBefore + 100e18) / STREAM_DURATION;
        assertApproxEqAbs(vault.rewardRate(), expectedRate, 1, "rate merges residual + fresh");
        assertEq(vault.periodFinish(), uint64(block.timestamp) + STREAM_DURATION);
    }

    function test_undistributedRewards_decreasesLinearly() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(pool);
        vault.notifyRewards(100e18);

        uint256 t0 = vault.undistributedRewards();
        vm.warp(block.timestamp + STREAM_DURATION / 4);
        uint256 t1 = vault.undistributedRewards();
        vm.warp(block.timestamp + STREAM_DURATION / 4);
        uint256 t2 = vault.undistributedRewards();

        assertGt(t0, t1, "decays");
        assertGt(t1, t2, "decays");
        // Roughly linear: each step should release ~25% of the bundle.
        assertApproxEqAbs(t0 - t1, t1 - t2, 1e12, "linear-ish decay");
    }

    function test_dustReleasedAfterPeriodFinish() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        // Pick an amount that does NOT cleanly divide by STREAM_DURATION (introduce dust).
        uint256 amount = 100e18 + 1;
        vm.prank(pool);
        vault.notifyRewards(amount);

        vm.warp(block.timestamp + STREAM_DURATION + 1);
        assertEq(vault.undistributedRewards(), 0, "no undistributed after periodFinish");
        // totalAssets must include the full amount (including the truncated dust).
        assertEq(vault.totalAssets(), 100e18 + amount, "dust visible post-finish");
    }

    function test_notifyRewards_worksWhilePaused() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(pauser);
        vault.pause();

        // The pool's reward machinery is intentionally not gated by the pause.
        vm.prank(pool);
        vault.notifyRewards(100e18);
        assertGt(vault.rewardRate(), 0);
    }

    function test_RevertIf_notifyRewards_zeroAmount() public {
        vm.prank(pool);
        vm.expectRevert(IstBlendErrors.ZeroAmount.selector);
        vault.notifyRewards(0);
    }

    function test_RevertIf_notifyRewards_rateZero() public {
        // amount < STREAM_DURATION → rate floor-divides to zero.
        vm.prank(pool);
        vm.expectRevert(IstBlendErrors.RewardRateZero.selector);
        vault.notifyRewards(STREAM_DURATION - 1);
    }

    function test_RevertIf_notifyRewards_notDistributor() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, REWARDS_DISTRIBUTOR_ROLE)
        );
        vault.notifyRewards(100e18);
    }

    // =========================================================================================
    // Cap / pause
    // =========================================================================================

    function test_maxDeposit_clampsToCap() public {
        vm.prank(admin);
        vault.setMaxTotalAssets(500e18);

        vm.prank(alice);
        vault.deposit(200e18, alice);

        assertEq(vault.maxDeposit(bob), 300e18, "remaining headroom");

        vm.prank(bob);
        vault.deposit(300e18, bob);

        assertEq(vault.maxDeposit(alice), 0, "fully capped");
    }

    function test_maxMint_clampsToCap() public {
        vm.prank(admin);
        vault.setMaxTotalAssets(500e18);
        assertEq(vault.maxMint(alice), vault.previewDeposit(500e18));
    }

    function test_maxDeposit_returnsZeroWhenAboveCap() public {
        vm.prank(alice);
        vault.deposit(200e18, alice);
        // Lower the cap below current TVL.
        vm.prank(admin);
        vault.setMaxTotalAssets(100e18);

        assertEq(vault.maxDeposit(bob), 0);
        assertEq(vault.maxMint(bob), 0);
    }

    function test_maxDeposit_returnsZeroWhenPaused() public {
        vm.prank(pauser);
        vault.pause();
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
    }

    function test_RevertIf_deposit_aboveCap() public {
        vm.prank(admin);
        vault.setMaxTotalAssets(100e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, alice, 200e18, 100e18)
        );
        vault.deposit(200e18, alice);
    }

    function test_setMaxTotalAssets_emitsEventAndUpdates() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit IstBlendEvents.MaxTotalAssetsUpdated(0, 500e18);
        vm.prank(admin);
        vault.setMaxTotalAssets(500e18);
        assertEq(vault.maxTotalAssets(), 500e18);
    }

    function test_RevertIf_setMaxTotalAssets_notAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE)
        );
        vault.setMaxTotalAssets(500e18);
    }

    function test_pause_blocksDepositAndTransfer() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(pauser);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, alice, 1, 0)
        );
        vault.deposit(1, alice);

        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        // The revert is asserted via expectRevert; the return value is irrelevant here.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        vault.transfer(bob, 1);
    }

    function test_pause_blocksWithdraw() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);
        vm.prank(pauser);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.withdraw(1, alice, alice);
    }

    function test_unpause_resumesOps() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(pauser);
        vault.pause();
        vm.prank(pauser);
        vault.unpause();

        vm.prank(alice);
        vault.deposit(1e18, alice);
        assertEq(vault.balanceOf(alice), 101e18);
    }

    function test_RevertIf_pause_notPauser() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, PAUSER_ROLE)
        );
        vault.pause();
    }

    function test_RevertIf_unpause_notPauser() public {
        vm.prank(pauser);
        vault.pause();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, PAUSER_ROLE)
        );
        vault.unpause();
    }

    // =========================================================================================
    // EIP-712 staking signatures
    // =========================================================================================

    function test_depositWithSig_executesOnBehalfOfSigner() public {
        uint256 assets = 50e18;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signDepositPermit(aliceKey, alice, bob, assets, vault.stakingNonces(alice), deadline);

        // Relayer (NOT alice) submits the tx; the vault pulls underlying from alice's allowance.
        vm.expectEmit(true, false, false, true, address(vault));
        emit IstBlendEvents.StakingSignatureUsed(alice, 0);
        vm.prank(relayer);
        uint256 shares = vault.depositWithSig(assets, bob, alice, deadline, v, r, s);
        assertEq(shares, assets, "1:1 deposit");
        assertEq(vault.balanceOf(bob), assets, "shares minted to receiver");
        assertEq(vault.balanceOf(alice), 0, "owner did not receive shares");
        assertEq(vault.stakingNonces(alice), 1, "nonce consumed");
    }

    function test_mintWithSig_executesOnBehalfOfSigner() public {
        uint256 shares = 30e18;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signMintPermit(aliceKey, alice, bob, shares, vault.stakingNonces(alice), deadline);

        vm.prank(relayer);
        uint256 assetsIn = vault.mintWithSig(shares, bob, alice, deadline, v, r, s);
        assertEq(assetsIn, shares, "1:1 mint pre-rewards");
        assertEq(vault.balanceOf(bob), shares);
    }

    function test_stakingNonces_separateFromERC2612Nonces() public {
        // Consume a staking nonce.
        (uint8 v, bytes32 r, bytes32 s) = _signDepositPermit(aliceKey, alice, alice, 1e18, 0, block.timestamp + 1 hours);
        vm.prank(relayer);
        vault.depositWithSig(1e18, alice, alice, block.timestamp + 1 hours, v, r, s);

        // EIP-2612 share-permit nonce is still untouched.
        assertEq(vault.stakingNonces(alice), 1);
        assertEq(vault.nonces(alice), 0);
    }

    function test_RevertIf_depositWithSig_expired() public {
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signDepositPermit(aliceKey, alice, alice, 1e18, 0, deadline);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IstBlendErrors.ExpiredSignature.selector, deadline));
        vault.depositWithSig(1e18, alice, alice, deadline, v, r, s);
    }

    function test_RevertIf_depositWithSig_replay() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signDepositPermit(aliceKey, alice, alice, 1e18, 0, deadline);

        vm.prank(relayer);
        vault.depositWithSig(1e18, alice, alice, deadline, v, r, s);

        // Re-using the same signature should fail because the nonce has advanced.
        vm.prank(relayer);
        vm.expectRevert(); // recovered signer will not match alice — InvalidSigner
        vault.depositWithSig(1e18, alice, alice, deadline, v, r, s);
    }

    function test_RevertIf_depositWithSig_signedByOther() public {
        uint256 wrongKey = 0xB0B;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signDepositPermit(wrongKey, alice, alice, 1e18, 0, deadline);
        address recovered = vm.addr(wrongKey);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IstBlendErrors.InvalidSigner.selector, recovered, alice));
        vault.depositWithSig(1e18, alice, alice, deadline, v, r, s);
    }

    function test_RevertIf_depositWithSig_zeroAssets() public {
        vm.prank(relayer);
        vm.expectRevert(IstBlendErrors.ZeroAmount.selector);
        vault.depositWithSig(0, alice, alice, block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));
    }

    function test_RevertIf_depositWithSig_zeroOwner() public {
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IstBlendErrors.ZeroAddressNotAllowed.selector, "owner"));
        vault.depositWithSig(1e18, alice, address(0), block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));
    }

    function test_RevertIf_depositWithSig_zeroReceiver() public {
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IstBlendErrors.ZeroAddressNotAllowed.selector, "receiver"));
        vault.depositWithSig(1e18, address(0), alice, block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));
    }

    function test_RevertIf_depositWithSig_capExceeded() public {
        vm.prank(admin);
        vault.setMaxTotalAssets(10e18);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signDepositPermit(aliceKey, alice, alice, 50e18, 0, deadline);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, alice, 50e18, 10e18)
        );
        vault.depositWithSig(50e18, alice, alice, deadline, v, r, s);
    }

    function test_RevertIf_mintWithSig_zeroShares() public {
        vm.prank(relayer);
        vm.expectRevert(IstBlendErrors.ZeroAmount.selector);
        vault.mintWithSig(0, alice, alice, block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));
    }

    function test_RevertIf_mintWithSig_replay() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signMintPermit(aliceKey, alice, alice, 1e18, 0, deadline);
        vm.prank(relayer);
        vault.mintWithSig(1e18, alice, alice, deadline, v, r, s);

        vm.prank(relayer);
        vm.expectRevert();
        vault.mintWithSig(1e18, alice, alice, deadline, v, r, s);
    }

    function test_RevertIf_mintWithSig_capExceeded() public {
        vm.prank(admin);
        vault.setMaxTotalAssets(10e18);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signMintPermit(aliceKey, alice, alice, 50e18, 0, deadline);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxMint.selector, alice, 50e18, 10e18)
        );
        vault.mintWithSig(50e18, alice, alice, deadline, v, r, s);
    }

    // =========================================================================================
    // Admin setters
    // =========================================================================================

    function test_setStreamDuration_emitsAndUpdates() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit IstBlendEvents.StreamDurationUpdated(STREAM_DURATION, 2 days);
        vm.prank(admin);
        vault.setStreamDuration(2 days);
        assertEq(vault.streamDuration(), 2 days);
    }

    function test_setStreamDuration_appliesOnNextNotify() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(admin);
        vault.setStreamDuration(2 days);

        vm.prank(pool);
        vault.notifyRewards(100e18);
        assertEq(vault.periodFinish(), uint64(block.timestamp) + 2 days);
    }

    function test_RevertIf_setStreamDuration_tooShort() public {
        // Cache views BEFORE the prank — vm.prank is one-shot and would otherwise be
        // consumed by the view calls inside the abi.encodeWithSelector args.
        uint64 min = vault.MIN_STREAM_DURATION();
        uint64 max = vault.MAX_STREAM_DURATION();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IstBlendErrors.InvalidStreamDuration.selector, 1 minutes, min, max));
        vault.setStreamDuration(1 minutes);
    }

    function test_RevertIf_setStreamDuration_tooLong() public {
        uint64 min = vault.MIN_STREAM_DURATION();
        uint64 max = vault.MAX_STREAM_DURATION();
        uint64 tooLong = max + 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IstBlendErrors.InvalidStreamDuration.selector, tooLong, min, max));
        vault.setStreamDuration(tooLong);
    }

    function test_RevertIf_setStreamDuration_notAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE)
        );
        vault.setStreamDuration(2 days);
    }

    // =========================================================================================
    // Upgrade authorisation
    // =========================================================================================

    function test_upgradeTo_byUpgrader() public {
        stBlend next = new stBlend();
        vm.prank(admin);
        vault.upgradeToAndCall(address(next), "");
        // Sanity: the proxy still answers — same role config, no storage corruption.
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    function test_RevertIf_upgradeTo_notUpgrader() public {
        stBlend next = new stBlend();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, UPGRADER_ROLE)
        );
        vault.upgradeToAndCall(address(next), "");
    }

    // =========================================================================================
    // EIP-712 helpers
    // =========================================================================================

    function _signDepositPermit(
        uint256 privateKey,
        address owner,
        address receiver,
        uint256 assets,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(vault.DEPOSIT_PERMIT_TYPEHASH(), owner, receiver, assets, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(privateKey, digest);
    }

    function _signMintPermit(
        uint256 privateKey,
        address owner,
        address receiver,
        uint256 shares,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(vault.MINT_PERMIT_TYPEHASH(), owner, receiver, shares, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(privateKey, digest);
    }
}
