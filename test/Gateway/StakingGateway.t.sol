// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {stBlend} from "../../contracts/stBlend/stBlend.sol";
import {StakingGateway} from "../../contracts/gateways/StakingGateway.sol";
import {
    IStakingGateway,
    IStakingGatewayErrors,
    IStakingGatewayEvents
} from "../../contracts/interfaces/gateways/IStakingGateway.sol";
import {IGatewayBaseErrors} from "../../contracts/interfaces/gateways/IGatewayBase.sol";
import {StakedTokenMirror} from "../../contracts/tokens/StakedTokenMirror.sol";
import {MockERC20Token} from "../mocks/MockERC20.sol";
import {GatewayBase} from "./Base.t.sol";

contract StakingGatewayTest is GatewayBase {
    MockERC20Token internal asset;
    stBlend internal vault;
    StakedTokenMirror internal mirrorToken;
    StakingGateway internal l1Gateway;
    StakingGateway internal l2Gateway;

    address internal pool = makeAddr("pool");
    address internal l1Recipient = makeAddr("l1Recipient");
    address internal l2Recipient = makeAddr("l2Recipient");

    function setUp() public override {
        super.setUp();
        _deployBridge(0);
        _deployStakingStack();
    }

    function _deployStakingStack() internal {
        asset = new MockERC20Token("Fluent", "FLUENT", 2_000_000 ether, address(this));

        stBlend vaultImpl = new stBlend();
        vault = stBlend(
            address(
                new ERC1967Proxy(
                    address(vaultImpl),
                    abi.encodeCall(
                        stBlend.initialize,
                        (IERC20(address(asset)), "Staked Fluent", "sFLUENT", admin, admin, pool, 1 days, 0)
                    )
                )
            )
        );

        StakedTokenMirror mirrorImpl = new StakedTokenMirror();
        mirrorToken = StakedTokenMirror(
            address(new ERC1967Proxy(address(mirrorImpl), abi.encodeCall(StakedTokenMirror.initialize, ("Staked Fluent", "sFLUENT", 18, admin))))
        );

        StakingGateway gatewayImpl = new StakingGateway();
        l1Gateway = StakingGateway(
            address(
                new ERC1967Proxy(
                    address(gatewayImpl),
                    abi.encodeCall(StakingGateway.initialize, (admin, address(bridge), address(asset), address(0), address(mirrorToken), false))
                )
            )
        );
        l2Gateway = StakingGateway(
            address(
                new ERC1967Proxy(
                    address(gatewayImpl),
                    abi.encodeCall(StakingGateway.initialize, (admin, address(bridge), address(asset), address(vault), address(0), true))
                )
            )
        );

        vm.prank(admin);
        l1Gateway.setOtherSideGateway(address(l2Gateway));
        vm.prank(admin);
        l2Gateway.setOtherSideGateway(address(l1Gateway));

        _registerGateway(address(l1Gateway));
        _registerGateway(address(l2Gateway));

        vm.prank(admin);
        mirrorToken.transferOwnership(address(l1Gateway));
        vm.prank(admin);
        l1Gateway.acceptMirrorTokenOwnership();

        asset.transfer(user, 100_000 ether);
        asset.transfer(address(l2Gateway), 100_000 ether);
        asset.transfer(address(l1Gateway), 100_000 ether);

        vm.prank(user);
        asset.approve(address(l1Gateway), type(uint256).max);
        vm.prank(user);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(user);
        vault.approve(address(l2Gateway), type(uint256).max);
    }

    // ============ Deployment ============

    function test_initialize_setsGatewayConfig() public view {
        assertEq(l1Gateway.owner(), admin);
        assertEq(l1Gateway.getBridgeContract(), address(bridge));
        assertEq(l1Gateway.getUnderlying(), address(asset));
        assertEq(l1Gateway.getMirrorToken(), address(mirrorToken));
        assertFalse(l1Gateway.isL2Canonical());

        assertEq(l2Gateway.getVault(), address(vault));
        assertTrue(l2Gateway.isL2Canonical());
        assertEq(mirrorToken.owner(), address(l1Gateway));
    }

    function test_RevertIf_l1FunctionCalledOnL2Mode() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IStakingGatewayErrors.InvalidGatewayMode.selector, false));
        l2Gateway.depositAndStake(1 ether, l2Recipient);
    }

    function test_RevertIf_l2FunctionCalledOnL1Mode() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IStakingGatewayErrors.InvalidGatewayMode.selector, true));
        l1Gateway.redeemToL1(1 ether, l1Recipient);
    }

    // ============ L1 -> L2 stake ============

    function test_depositAndStake_escrowsUnderlyingAndSendsMessage() public {
        uint256 amount = 10 ether;
        uint256 beforeBalance = asset.balanceOf(address(l1Gateway));

        vm.expectEmit(true, true, false, true, address(l1Gateway));
        emit IStakingGatewayEvents.DepositAndStakeInitiated(user, l2Recipient, amount);
        vm.prank(user);
        l1Gateway.depositAndStake(amount, l2Recipient);

        assertEq(asset.balanceOf(address(l1Gateway)), beforeBalance + amount);
        assertEq(asset.balanceOf(user), 100_000 ether - amount);
    }

    function test_receiveDepositAndStake_depositsInventoryIntoVault() public {
        uint256 amount = 25 ether;
        bytes memory message = abi.encodeCall(IStakingGateway.receiveDepositAndStake, (user, l2Recipient, amount));

        _relayMessage(address(l1Gateway), address(l2Gateway), 0, message);

        assertEq(vault.balanceOf(l2Recipient), amount);
        assertEq(vault.totalAssets(), amount);
        assertEq(asset.balanceOf(address(l2Gateway)), 100_000 ether - amount);
    }

    function test_RevertIf_receiveDepositAndStake_wrongGateway() public {
        vm.prank(address(bridge));
        vm.expectRevert(IGatewayBaseErrors.MessageFromWrongGateway.selector);
        l2Gateway.receiveDepositAndStake(user, l2Recipient, 1 ether);
    }

    // ============ L2 -> L1 redeem ============

    function test_redeemToL1_redeemsSharesIntoL2InventoryAndSendsMessage() public {
        uint256 amount = 40 ether;
        vm.prank(user);
        vault.deposit(amount, user);

        uint256 beforeInventory = asset.balanceOf(address(l2Gateway));

        vm.expectEmit(true, true, false, true, address(l2Gateway));
        emit IStakingGatewayEvents.RedeemToL1Initiated(user, l1Recipient, amount, amount);
        vm.prank(user);
        uint256 assets = l2Gateway.redeemToL1(amount, l1Recipient);

        assertEq(assets, amount);
        assertEq(vault.balanceOf(user), 0);
        assertEq(asset.balanceOf(address(l2Gateway)), beforeInventory + amount);
    }

    function test_receiveUnderlyingWithdrawal_releasesL1Escrow() public {
        uint256 amount = 15 ether;
        uint256 beforeGateway = asset.balanceOf(address(l1Gateway));
        uint256 beforeRecipient = asset.balanceOf(l1Recipient);
        bytes memory message = abi.encodeCall(IStakingGateway.receiveUnderlyingWithdrawal, (user, l1Recipient, amount));

        _relayMessage(address(l2Gateway), address(l1Gateway), 0, message);

        assertEq(asset.balanceOf(address(l1Gateway)), beforeGateway - amount);
        assertEq(asset.balanceOf(l1Recipient), beforeRecipient + amount);
    }

    // ============ Native share bridge ============

    function test_sendSharesToL1_locksCanonicalSharesAndSendsMessage() public {
        uint256 shares = 12 ether;
        vm.prank(user);
        vault.deposit(shares, user);

        vm.expectEmit(true, true, false, true, address(l2Gateway));
        emit IStakingGatewayEvents.SharesToL1Initiated(user, l1Recipient, shares);
        vm.prank(user);
        l2Gateway.sendSharesToL1(shares, l1Recipient);

        assertEq(vault.balanceOf(user), 0);
        assertEq(vault.balanceOf(address(l2Gateway)), shares);
    }

    function test_receiveSharesToL1_mintsMirrorShares() public {
        uint256 shares = 12 ether;
        bytes memory message = abi.encodeCall(IStakingGateway.receiveSharesToL1, (user, l1Recipient, shares));

        _relayMessage(address(l2Gateway), address(l1Gateway), 0, message);

        assertEq(mirrorToken.balanceOf(l1Recipient), shares);
    }

    function test_sendSharesToL2_burnsMirrorSharesAndSendsMessage() public {
        uint256 shares = 7 ether;
        bytes memory mintMessage = abi.encodeCall(IStakingGateway.receiveSharesToL1, (user, user, shares));
        _relayMessage(address(l2Gateway), address(l1Gateway), 0, mintMessage);
        assertEq(mirrorToken.balanceOf(user), shares);

        vm.expectEmit(true, true, false, true, address(l1Gateway));
        emit IStakingGatewayEvents.SharesToL2Initiated(user, l2Recipient, shares);
        vm.prank(user);
        l1Gateway.sendSharesToL2(shares, l2Recipient);

        assertEq(mirrorToken.balanceOf(user), 0);
    }

    function test_receiveSharesToL2_releasesLockedCanonicalShares() public {
        uint256 shares = 9 ether;
        vm.prank(user);
        vault.deposit(shares, user);
        vm.prank(user);
        l2Gateway.sendSharesToL1(shares, l1Recipient);

        bytes memory message = abi.encodeCall(IStakingGateway.receiveSharesToL2, (l1Recipient, l2Recipient, shares));
        _relayMessage(address(l1Gateway), address(l2Gateway), 0, message);

        assertEq(vault.balanceOf(address(l2Gateway)), 0);
        assertEq(vault.balanceOf(l2Recipient), shares);
    }

    // ============ Validation ============

    function test_RevertIf_depositAndStake_zeroAmount() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IGatewayBaseErrors.ZeroValueNotAllowed.selector, "assets"));
        l1Gateway.depositAndStake(0, l2Recipient);
    }

    function test_RevertIf_depositAndStake_zeroReceiver() public {
        vm.prank(user);
        vm.expectRevert(IGatewayBaseErrors.InvalidRecipient.selector);
        l1Gateway.depositAndStake(1 ether, address(0));
    }

    function test_RevertIf_sendSharesToL1_zeroShares() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IGatewayBaseErrors.ZeroValueNotAllowed.selector, "shares"));
        l2Gateway.sendSharesToL1(0, l1Recipient);
    }
}
