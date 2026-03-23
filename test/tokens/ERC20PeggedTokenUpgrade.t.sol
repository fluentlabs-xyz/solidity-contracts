// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {GatewayBase} from "../Gateway/Base.t.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {IERC20Gateway} from "../../contracts/interfaces/gateways/IERC20Gateway.sol";
import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";

/// @dev V2 implementation adds a version getter to prove new logic is reachable after beacon upgrade.
contract ERC20PeggedTokenV2 is ERC20PeggedToken {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract ERC20PeggedTokenUpgradeTest is GatewayBase {
    address internal peggedToken;

    function setUp() public override {
        super.setUp();
        _deployBridge(0);
        _deployGatewayStack();
        peggedToken = _deployPeggedViaGateway();
    }

    /// @dev Simulates the full cross-chain flow: relay a receivePeggedTokens message through
    ///      the bridge so the gateway deploys and initializes a pegged token via the factory.
    function _deployPeggedViaGateway() internal returns (address) {
        address origin = address(originToken);
        address predicted = _predictedPegged();

        bytes memory tokenMetadata = abi.encode(originToken.symbol(), originToken.name(), originToken.decimals());
        bytes memory message = abi.encodeCall(
            IERC20Gateway.receivePeggedTokens,
            (origin, predicted, user, recipient, 1000 ether, tokenMetadata)
        );

        _relayMessage(remoteGateway, address(gateway), 0, message);

        return predicted;
    }

    // ============ Pre-upgrade sanity ============

    function test_preUpgrade_metadataAndBalances() public view {
        ERC20PeggedToken token = ERC20PeggedToken(peggedToken);

        assertEq(token.name(), "Mock Token");
        assertEq(token.symbol(), "MOCK");
        assertEq(token.decimals(), 18);
        assertEq(token.balanceOf(recipient), 1000 ether);
        assertEq(token.owner(), address(gateway));
    }

    // ============ Beacon upgrade ============

    function test_beaconUpgrade_preservesStorageAndAddsNewLogic() public {
        ERC20PeggedToken token = ERC20PeggedToken(peggedToken);

        // --- snapshot pre-upgrade state ---
        string memory nameBefore = token.name();
        string memory symbolBefore = token.symbol();
        uint8 decimalsBefore = token.decimals();
        uint256 balanceBefore = token.balanceOf(recipient);
        address ownerBefore = token.owner();

        // --- deploy V2 and upgrade the beacon ---
        ERC20PeggedTokenV2 v2Impl = new ERC20PeggedTokenV2();
        vm.prank(admin);
        factory.upgradeTo(address(v2Impl));

        // --- verify implementation changed ---
        assertEq(factory.implementation(), address(v2Impl));

        // --- verify all storage is preserved ---
        assertEq(token.name(), nameBefore);
        assertEq(token.symbol(), symbolBefore);
        assertEq(token.decimals(), decimalsBefore);
        assertEq(token.balanceOf(recipient), balanceBefore);
        assertEq(token.owner(), ownerBefore);

        // --- verify new V2 logic is accessible ---
        assertEq(ERC20PeggedTokenV2(peggedToken).version(), 2);
    }

    function test_beaconUpgrade_mintAndBurnStillWork() public {
        // --- upgrade ---
        ERC20PeggedTokenV2 v2Impl = new ERC20PeggedTokenV2();
        vm.prank(admin);
        factory.upgradeTo(address(v2Impl));

        ERC20PeggedToken token = ERC20PeggedToken(peggedToken);
        uint256 balanceBefore = token.balanceOf(recipient);

        // --- mint via gateway (relay another receivePeggedTokens) ---
        address origin = address(originToken);
        bytes memory tokenMetadata = abi.encode(originToken.symbol(), originToken.name(), originToken.decimals());
        bytes memory mintMsg = abi.encodeCall(
            IERC20Gateway.receivePeggedTokens,
            (origin, peggedToken, user, recipient, 500 ether, tokenMetadata)
        );
        _relayMessage(remoteGateway, address(gateway), 0, mintMsg);

        assertEq(token.balanceOf(recipient), balanceBefore + 500 ether);

        // --- burn via gateway (sendTokens triggers _sendPeggedTokens → burn) ---
        vm.prank(recipient);
        token.approve(address(gateway), 200 ether);
        vm.prank(recipient);
        gateway.sendTokens(peggedToken, user, 200 ether);

        assertEq(token.balanceOf(recipient), balanceBefore + 500 ether - 200 ether);
    }

    function test_beaconUpgrade_pauseStillWorks() public {
        // --- upgrade ---
        ERC20PeggedTokenV2 v2Impl = new ERC20PeggedTokenV2();
        vm.prank(admin);
        factory.upgradeTo(address(v2Impl));

        ERC20PeggedToken token = ERC20PeggedToken(peggedToken);

        // gateway is the owner → can pause
        vm.prank(address(gateway));
        token.pause();
        assertTrue(token.paused());

        // transfers revert while paused
        vm.prank(recipient);
        vm.expectRevert(ERC20PeggedToken.TokenPaused.selector);
        token.transfer(user, 1);

        // unpause and transfer works
        vm.prank(address(gateway));
        token.unpause();

        vm.prank(recipient);
        token.transfer(user, 1);
        assertEq(token.balanceOf(user), 1);
    }
}
