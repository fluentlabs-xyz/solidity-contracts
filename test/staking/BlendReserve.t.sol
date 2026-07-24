// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {BlendReserve} from "../../contracts/staking/BlendReserve.sol";
import {MockBlendToken} from "../../contracts/staking/mocks/MockBlendToken.sol";

/// @notice A plain fixed-supply ERC20 (no callable mint) — the production-shaped BLEND.
contract FixedSupplyToken is ERC20 {
    constructor() ERC20("Fixed", "FIX") {
        _mint(msg.sender, 1_000_000 ether);
    }
}
import {IStakingContextErrors} from "../../contracts/staking/interfaces/IStakingContext.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {ISystemReward} from "../../contracts/staking/interfaces/ISystemReward.sol";
import {IStakingPool} from "../../contracts/staking/interfaces/IStakingPool.sol";
import {IFluentGovernance} from "../../contracts/staking/interfaces/IFluentGovernance.sol";
import {IChainConfig} from "../../contracts/staking/interfaces/IChainConfig.sol";

contract BlendReserveTest is Test {
    BlendReserve internal reserve;
    MockBlendToken internal blend;
    address internal to = makeAddr("to");
    // This test contract stands in for the Staking predeploy (disburse caller) and governance.

    function setUp() public {
        blend = new MockBlendToken();
        BlendReserve impl = new BlendReserve(
            IStaking(payable(address(0xdead))),
            ISystemReward(payable(address(0xdead))),
            IStakingPool(payable(address(0xdead))),
            IFluentGovernance(address(this)),
            IChainConfig(address(0xdead)),
            blend,
            address(this) // stakingAddr == this test (so we can call disburse)
        );
        reserve = BlendReserve(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(BlendReserve.initialize, (address(this)))))
        );
        blend.mint(address(reserve), 1000 ether);
    }

    function test_disburseClampsToBalance() public {
        uint256 sent = reserve.disburse(to, 1500 ether); // asks more than the 1000 held
        assertEq(sent, 1000 ether);
        assertEq(blend.balanceOf(to), 1000 ether);
        assertEq(reserve.reserveBalance(), 0);
    }

    function test_disburseExactUnderBalance() public {
        uint256 sent = reserve.disburse(to, 400 ether);
        assertEq(sent, 400 ether);
        assertEq(reserve.reserveBalance(), 600 ether);
    }

    function test_onlyStakingCanDisburse() public {
        vm.prank(makeAddr("rogue"));
        vm.expectRevert(IStakingContextErrors.OnlyStakingContract.selector);
        reserve.disburse(to, 1 ether);
    }

    function test_pauseBlocksDisburse() public {
        reserve.setPaused(true);
        assertTrue(reserve.isPaused());
        uint256 sent = reserve.disburse(to, 100 ether);
        assertEq(sent, 0, "paused reserve disburses nothing");
        assertEq(reserve.reserveBalance(), 1000 ether);
    }

    function test_onlyGovernanceCanPause() public {
        vm.prank(makeAddr("rogue"));
        vm.expectRevert(IStakingContextErrors.OnlyGovernanceContract.selector);
        reserve.setPaused(true);
    }

    /// G9 (F5): the deploy gate `DeployStaking._assertFixedSupplyToken` now pins the canonical BLEND by
    /// ADDRESS (`EXPECTED_BLEND`), not by inferring immutability from a `mint()` revert. The mock BLEND is
    /// intentionally mintable — valid on local/devnet where the gate is skipped (EXPECTED_BLEND unset);
    /// production pins the address so a mintable token can never be the staking token even if it also
    /// happened to expose a matching mint signature.
    function test_mockBlendIsMintableAndGatedByAddressInProd() public {
        (bool okMock,) =
            address(blend).call(abi.encodeWithSignature("mint(address,uint256)", address(0xdead), uint256(0)));
        assertTrue(okMock, "mock BLEND is intentionally mintable (devnet only; prod gate is an address pin)");

        FixedSupplyToken fixedTok = new FixedSupplyToken();
        (bool okFixed,) =
            address(fixedTok).call(abi.encodeWithSignature("mint(address,uint256)", address(0xdead), uint256(0)));
        assertFalse(okFixed, "a fixed-supply token has no callable mint");
    }
}
