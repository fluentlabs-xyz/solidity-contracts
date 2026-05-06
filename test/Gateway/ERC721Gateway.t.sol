// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC721Gateway} from "../../contracts/gateways/ERC721Gateway.sol";
import {ERC721PeggedToken} from "../../contracts/gateways/ERC721PeggedToken.sol";
import {IERC721Gateway, IERC721GatewayErrors} from "../../contracts/gateways/IERC721Gateway.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {ERC721GatewayBase} from "./ERC721GatewayBase.t.sol";

contract ERC721GatewayTest is ERC721GatewayBase {
    function setUp() public override {
        super.setUp();
        _deployBridge();
        _deployERC721GatewayStack();
    }

    function test_receivePeggedToken_deploysAndMints() public {
        uint256 tokenId = 1;
        address predicted = _predictedPegged();
        bytes memory meta = abi.encode("Mock Collection", "MCOL", "uri://1");
        bytes memory message = abi.encodeCall(
            ERC721Gateway.receivePeggedToken,
            (address(originNft), predicted, user, recipient, tokenId, meta)
        );
        _relayMessage(remoteGateway, address(gateway), 0, message);

        assertEq(gateway.getTokenMapping(predicted), address(originNft));
        assertEq(IERC721(predicted).ownerOf(tokenId), recipient);
        assertEq(keccak256(bytes(ERC721PeggedToken(predicted).tokenURI(tokenId))), keccak256(bytes("uri://1")));
    }

    function test_sendToken_origin_escrowsNft() public {
        uint256 tokenId = 1;
        uint256 fee = _bridgeFee();
        vm.prank(user);
        originNft.setApprovalForAll(address(gateway), true);
        vm.prank(user);
        gateway.sendToken{value: fee}(address(originNft), recipient, tokenId);
        assertEq(IERC721(address(originNft)).ownerOf(tokenId), address(gateway));
    }

    function test_sendToken_pegged_burns() public {
        uint256 tokenId = 42;
        address predicted = _predictedPegged();
        bytes memory meta = abi.encode("Mock Collection", "MCOL", "uri://42");
        bytes memory message = abi.encodeCall(
            ERC721Gateway.receivePeggedToken,
            (address(originNft), predicted, user, user, tokenId, meta)
        );
        _relayMessage(remoteGateway, address(gateway), 0, message);

        ERC721PeggedToken pegged = ERC721PeggedToken(predicted);
        assertEq(pegged.ownerOf(tokenId), user);

        uint256 fee = _bridgeFee();
        vm.prank(user);
        pegged.setApprovalForAll(address(gateway), true);
        vm.prank(user);
        gateway.sendToken{value: fee}(predicted, recipient, tokenId);
        vm.expectRevert();
        pegged.ownerOf(tokenId);
    }

    function test_receiveOriginToken_releasesEscrow() public {
        uint256 tokenId = 7;
        vm.prank(user);
        originNft.mint(user, tokenId);

        uint256 fee = _bridgeFee();
        vm.prank(user);
        originNft.setApprovalForAll(address(gateway), true);
        vm.prank(user);
        gateway.sendToken{value: fee}(address(originNft), recipient, tokenId);
        assertEq(IERC721(address(originNft)).ownerOf(tokenId), address(gateway));

        bytes memory message = abi.encodeCall(ERC721Gateway.receiveOriginToken, (address(originNft), user, recipient, tokenId));
        _relayMessage(remoteGateway, address(gateway), 0, message);
        assertEq(IERC721(address(originNft)).ownerOf(tokenId), recipient);
    }

    function test_setBridgingExcludedOrigin_blocksSend() public {
        vm.prank(admin);
        gateway.setBridgingExcludedOrigin(address(originNft), true);

        uint256 fee = _bridgeFee();
        vm.prank(user);
        originNft.setApprovalForAll(address(gateway), true);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IERC721GatewayErrors.BridgingExcludedOriginToken.selector, address(originNft)));
        gateway.sendToken{value: fee}(address(originNft), recipient, 1);
    }
}
