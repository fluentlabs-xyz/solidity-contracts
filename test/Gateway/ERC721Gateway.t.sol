// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ERC721Gateway} from "../../contracts/gateways/ERC721Gateway.sol";
import {ERC721TokenFactory} from "../../contracts/factories/ERC721TokenFactory.sol";
import {ERC721PeggedToken} from "../../contracts/tokens/ERC721PeggedToken.sol";
import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {MockERC721Token} from "../mocks/MockERC721.sol";
import {GatewayBase} from "./Base.t.sol";

contract ERC721GatewayTest is GatewayBase {
    ERC721Gateway internal nftGateway;
    ERC721TokenFactory internal nftFactory;
    ERC721PeggedToken internal nftImplementation;
    MockERC721Token internal originNft;

    function setUp() public override {
        super.setUp();
        recipient = makeAddr("recipient");
        _deployBridge(0);
        _deployNftGatewayStack();
    }

    function test_sendToken_originPath_escrowsToken() public {
        originNft.mint(user, 1, "ipfs://one");

        vm.prank(user);
        originNft.approve(address(nftGateway), 1);
        vm.prank(user);
        nftGateway.sendToken(address(originNft), recipient, 1);

        assertEq(originNft.ownerOf(1), address(nftGateway));
    }

    function test_receivePeggedToken_deploysAndMints() public {
        address predicted = nftGateway.computeTokenAddress(address(nftGateway), address(originNft));
        bytes memory metadata = abi.encode("Mock NFT", "MNFT", "ipfs://one");
        bytes memory message = abi.encodeCall(
            ERC721Gateway.receivePeggedToken, (address(originNft), predicted, user, recipient, 1, metadata)
        );

        _relayMessage(remoteGateway, address(nftGateway), 0, message);

        assertEq(nftGateway.getTokenMapping(predicted), address(originNft));
        assertEq(ERC721PeggedToken(predicted).ownerOf(1), recipient);
        assertEq(ERC721PeggedToken(predicted).tokenURI(1), "ipfs://one");
    }

    function test_sendToken_peggedPath_burnsToken() public {
        address predicted = nftGateway.computeTokenAddress(address(nftGateway), address(originNft));
        bytes memory metadata = abi.encode("Mock NFT", "MNFT", "ipfs://one");
        bytes memory message =
            abi.encodeCall(ERC721Gateway.receivePeggedToken, (address(originNft), predicted, user, user, 1, metadata));
        _relayMessage(remoteGateway, address(nftGateway), 0, message);

        vm.prank(user);
        ERC721PeggedToken(predicted).approve(address(nftGateway), 1);
        vm.prank(user);
        nftGateway.sendToken(predicted, recipient, 1);

        vm.expectRevert();
        ERC721PeggedToken(predicted).ownerOf(1);
    }

    function test_receiveOriginToken_releasesEscrowedToken() public {
        originNft.mint(address(nftGateway), 1, "ipfs://one");
        bytes memory message =
            abi.encodeCall(ERC721Gateway.receiveOriginToken, (address(originNft), user, recipient, 1));

        _relayMessage(remoteGateway, address(nftGateway), 0, message);

        assertEq(originNft.ownerOf(1), recipient);
    }

    function _deployNftGatewayStack() internal {
        nftImplementation = new ERC721PeggedToken();
        ERC721TokenFactory factoryImpl = new ERC721TokenFactory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl), abi.encodeCall(ERC721TokenFactory.initialize, (admin, address(nftImplementation)))
        );
        nftFactory = ERC721TokenFactory(address(factoryProxy));

        ERC721Gateway gatewayImpl = new ERC721Gateway();
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(
            address(gatewayImpl),
            abi.encodeCall(ERC721Gateway.initialize, (admin, address(bridge), address(nftFactory)))
        );
        nftGateway = ERC721Gateway(payable(address(gatewayProxy)));

        vm.prank(admin);
        nftFactory.setPaymentGateway(address(nftGateway));
        address beacon = nftFactory.beacon();
        vm.prank(admin);
        nftGateway.setOtherSide(remoteGateway, sourceChainId, address(nftFactory), beacon);

        _registerGateway(address(nftGateway));
        _registerGateway(remoteGateway);

        originNft = new MockERC721Token("Mock NFT", "MNFT");
    }
}
