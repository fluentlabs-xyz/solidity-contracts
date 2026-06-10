// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ChainConfig} from "../../contracts/staking/ChainConfig.sol";
import {IChainConfig} from "../../contracts/staking/interfaces/IChainConfig.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {ISystemReward} from "../../contracts/staking/interfaces/ISystemReward.sol";
import {IStakingPool} from "../../contracts/staking/interfaces/IStakingPool.sol";
import {IFluentGovernance} from "../../contracts/staking/interfaces/IFluentGovernance.sol";

/// @notice Unit tests for the audit-added ChainConfig guards: the
///         `MAX_ACTIVE_VALIDATORS` cap (P2-6), the F1 undelegation-window floor
///         (immutable `minUndelegateBlocks`), and the epoch-numbering
///         pending-locks on `setDposActivationBlock` / `setEpochBlockInterval`
///         (P2-14 / P2-15). The test contract IS the governance address, so it
///         calls the `onlyFromGovernance` setters directly.
contract ChainConfigGuardsTest is Test {
    uint256 internal constant FLOOR = 1000; // minUndelegateBlocks
    uint32 internal constant INTERVAL = 200;

    function _impl() internal returns (ChainConfig) {
        return new ChainConfig(
            IStaking(address(this)),
            ISystemReward(payable(address(this))),
            IStakingPool(payable(address(this))),
            IFluentGovernance(address(this)),
            IChainConfig(address(this)),
            IERC20(address(this)),
            FLOOR
        );
    }

    function _initData(uint32 activeLen, uint32 undelegatePeriod, uint64 activation)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            ChainConfig.initialize,
            (
                address(this),
                activeLen,
                INTERVAL,
                uint32(50),
                uint32(150),
                uint32(7),
                undelegatePeriod,
                uint256(1e18),
                uint256(1e18),
                activation
            )
        );
    }

    /// Deploy a ChainConfig proxy; this contract is governance + owner.
    /// `dposActivationBlock` lets activation tests arm a lock.
    function _deploy(uint32 activeLen, uint32 undelegatePeriod, uint64 activation)
        internal
        returns (ChainConfig)
    {
        ChainConfig impl = _impl();
        return ChainConfig(
            address(new ERC1967Proxy(address(impl), _initData(activeLen, undelegatePeriod, activation)))
        );
    }

    function _good() internal returns (ChainConfig) {
        // window = 5 * 200 = 1000 == FLOOR (boundary passes), activation unset.
        return _deploy(21, 5, 0);
    }

    // --- P2-6: MAX_ACTIVE_VALIDATORS cap ---------------------------------------

    function test_init_rejects_active_len_above_cap() public {
        address impl = address(_impl());
        bytes memory data = _initData(52, 5, 0);
        vm.expectRevert(abi.encodeWithSelector(IChainConfig.MaxActiveValidatorsExceeded.selector, uint32(52), uint32(51)));
        new ERC1967Proxy(impl, data);
    }

    function test_init_accepts_active_len_at_cap() public {
        ChainConfig cc = _deploy(51, 5, 0);
        assertEq(cc.getActiveValidatorsLength(), 51);
    }

    function test_setter_rejects_active_len_above_cap() public {
        ChainConfig cc = _good();
        vm.expectRevert(abi.encodeWithSelector(IChainConfig.MaxActiveValidatorsExceeded.selector, uint32(52), uint32(51)));
        cc.setActiveValidatorsLength(52);
    }

    function test_setter_accepts_active_len_at_cap() public {
        ChainConfig cc = _good();
        cc.setActiveValidatorsLength(51);
        assertEq(cc.getActiveValidatorsLength(), 51);
    }

    // --- F1: undelegation-window floor -----------------------------------------

    function test_init_rejects_window_below_floor() public {
        // 4 * 200 = 800 < 1000.
        address impl = address(_impl());
        bytes memory data = _initData(21, 4, 0);
        vm.expectRevert(abi.encodeWithSelector(IChainConfig.UndelegateWindowTooShort.selector, uint256(800), FLOOR));
        new ERC1967Proxy(impl, data);
    }

    function test_setUndelegatePeriod_rejects_below_floor() public {
        ChainConfig cc = _good();
        vm.expectRevert(abi.encodeWithSelector(IChainConfig.UndelegateWindowTooShort.selector, uint256(800), FLOOR));
        cc.setUndelegatePeriod(4); // 4 * 200 = 800 < 1000
    }

    function test_setUndelegatePeriod_accepts_at_floor() public {
        ChainConfig cc = _good();
        cc.setUndelegatePeriod(5); // 5 * 200 = 1000 == floor
        assertEq(cc.getUndelegatePeriod(), 5);
    }

    function test_setEpochBlockInterval_rejects_shrink_below_floor() public {
        ChainConfig cc = _good();
        // undelegatePeriod 5, shrink interval 200 -> 100 => window 500 < 1000.
        vm.expectRevert(abi.encodeWithSelector(IChainConfig.UndelegateWindowTooShort.selector, uint256(500), FLOOR));
        cc.setEpochBlockInterval(100);
    }

    // --- P2-14 / P2-15: epoch-numbering pending-locks --------------------------

    function test_setDposActivationBlock_locked_after_activation() public {
        // Arm activation at block 2000 (aligned to interval 200).
        ChainConfig cc = _deploy(21, 5, 2000);
        vm.roll(2500); // past activation
        vm.expectRevert(IChainConfig.DposAlreadyActive.selector);
        cc.setDposActivationBlock(4000);
    }

    function test_setDposActivationBlock_allowed_while_pending() public {
        ChainConfig cc = _deploy(21, 5, 2000);
        vm.roll(1500); // still before activation
        cc.setDposActivationBlock(4000);
        assertEq(cc.getDposActivationBlock(), 4000);
    }

    function test_setEpochBlockInterval_locked_after_activation() public {
        ChainConfig cc = _deploy(21, 5, 2000);
        vm.roll(2500);
        vm.expectRevert(IChainConfig.DposAlreadyActive.selector);
        cc.setEpochBlockInterval(400);
    }

    function test_setEpochBlockInterval_keeps_pending_activation_aligned() public {
        ChainConfig cc = _deploy(21, 5, 2000);
        vm.roll(1500);
        // 2000 % 300 != 0 -> must reject to keep the pending activation aligned.
        vm.expectRevert(IChainConfig.UnalignedActivationBlock.selector);
        cc.setEpochBlockInterval(300);
    }
}
