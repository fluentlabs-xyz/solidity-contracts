// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract ERC20PeggedTokenTest is Test {
    ERC20PeggedToken internal token;

    address internal gateway = makeAddr("gateway");
    address internal originAddr = makeAddr("originToken");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        ERC20PeggedToken impl = new ERC20PeggedToken();
        // Deploy via minimal proxy to allow initialization
        bytes memory initData = abi.encodeCall(ERC20PeggedToken.initialize, ("Wrapped ETH", "WETH", 18, gateway, originAddr));
        address proxy = address(new ERC1967Proxy(address(impl), initData));
        token = ERC20PeggedToken(proxy);
    }

    // ============ Metadata ============

    function test_name_returnsInitializedName() public view {
        assertEq(token.name(), "Wrapped ETH", "name mismatch");
    }

    function test_symbol_returnsInitializedSymbol() public view {
        assertEq(token.symbol(), "WETH", "symbol mismatch");
    }

    function test_decimals_returnsInitializedDecimals() public view {
        assertEq(token.decimals(), 18, "decimals mismatch");
    }

    // ============ getOrigin ============

    function test_getOrigin_returnsGatewayAndOriginAddress() public view {
        (address gw, address origin) = token.getOrigin();
        assertEq(gw, gateway, "gateway mismatch");
        assertEq(origin, originAddr, "origin mismatch");
    }

    // ============ Pause / Unpause ============

    function test_pause_preventsTransfer() public {
        token.mint(alice, 100e18);
        token.pause();

        vm.prank(alice);
        vm.expectRevert(ERC20PeggedToken.TokenPaused.selector);
        // The revert reason is asserted via `vm.expectRevert`, so the return value is irrelevant here.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(bob, 50e18);
    }

    function test_unpause_resumesTransfer() public {
        token.mint(alice, 100e18);
        token.pause();
        token.unpause();

        vm.prank(alice);
        require(token.transfer(bob, 50e18), "transfer failed");
        assertEq(token.balanceOf(bob), 50e18, "bob balance");
    }

    function test_RevertIf_pause_callerNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        token.pause();
    }

    function test_RevertIf_unpause_callerNotOwner() public {
        token.pause();
        vm.prank(alice);
        vm.expectRevert();
        token.unpause();
    }

    function test_RevertIf_mint_whenPaused() public {
        token.pause();
        vm.expectRevert(ERC20PeggedToken.TokenPaused.selector);
        token.mint(alice, 100e18);
    }

    function test_RevertIf_burn_whenPaused() public {
        token.mint(alice, 100e18);
        token.pause();
        vm.expectRevert(ERC20PeggedToken.TokenPaused.selector);
        token.burn(alice, 50e18);
    }

    // ============ supportsInterface ============

    function test_supportsInterface_IERC20() public view {
        assertTrue(token.supportsInterface(type(IERC20).interfaceId), "IERC20 not supported");
    }

    function test_supportsInterface_IERC20Metadata() public view {
        assertTrue(token.supportsInterface(type(IERC20Metadata).interfaceId), "IERC20Metadata not supported");
    }

    function test_supportsInterface_IERC165() public view {
        assertTrue(token.supportsInterface(type(IERC165).interfaceId), "IERC165 not supported");
    }

    function test_supportsInterface_unsupported() public view {
        assertFalse(token.supportsInterface(bytes4(0xffffffff)), "random interface should not be supported");
    }
}
