// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {IERC721GatewayErrors} from "../../contracts/interfaces/gateways/IERC721Gateway.sol";
import {IERC1155GatewayErrors} from "../../contracts/interfaces/gateways/IERC1155Gateway.sol";
import {ERC721Gateway} from "../../contracts/gateways/ERC721Gateway.sol";
import {ERC1155Gateway} from "../../contracts/gateways/ERC1155Gateway.sol";
import {ERC721TokenFactory} from "../../contracts/factories/ERC721TokenFactory.sol";
import {ERC1155TokenFactory} from "../../contracts/factories/ERC1155TokenFactory.sol";
import {ERC721PeggedToken} from "../../contracts/tokens/ERC721PeggedToken.sol";
import {ERC1155PeggedToken} from "../../contracts/tokens/ERC1155PeggedToken.sol";
import {MockERC721} from "../mocks/MockERC721.sol";
import {MockERC1155} from "../mocks/MockERC1155.sol";
import {MockNFTReceiver} from "../mocks/MockNFTReceiver.sol";
import {GatewayBase} from "./Base.t.sol";

contract ERC721GatewayTest is GatewayBase {
    ERC721Gateway internal nftGateway;
    ERC721TokenFactory internal nftFactory;
    ERC721PeggedToken internal nftPeggedImplementation;
    MockERC721 internal originNft;

    function setUp() public override {
        super.setUp();
        _deployBridge(0);
        _deployERC721GatewayStack();
    }

    function test_receivePeggedToken_viaBridge_deploysAndMints() public {
        uint256 tokenId = 7;
        address predicted = _predictedERC721Pegged();
        bytes memory tokenMetadata = abi.encode("Mock NFT", "MNFT");
        bytes memory message = abi.encodeCall(
            ERC721Gateway.receivePeggedToken,
            (address(originNft), predicted, user, recipient, tokenId, tokenMetadata, "ipfs://token-7")
        );

        _relayMessage(remoteGateway, address(nftGateway), 0, message);

        assertEq(nftGateway.getTokenMapping(predicted), address(originNft));
        assertEq(ERC721PeggedToken(predicted).ownerOf(tokenId), recipient);
        assertEq(ERC721PeggedToken(predicted).tokenURI(tokenId), "ipfs://token-7");
    }

    function test_sendToken_originPath_escrowsOnGateway() public {
        uint256 tokenId = 11;
        originNft.mint(user, tokenId, "ipfs://origin-11");
        vm.prank(user);
        originNft.approve(address(nftGateway), tokenId);

        vm.prank(user);
        nftGateway.sendToken(address(originNft), recipient, tokenId);

        assertEq(originNft.ownerOf(tokenId), address(nftGateway));
    }

    function test_sendToken_peggedPath_burnsAndMessagesOriginRelease() public {
        uint256 tokenId = 13;
        address predicted = _predictedERC721Pegged();
        bytes memory tokenMetadata = abi.encode("Mock NFT", "MNFT");
        bytes memory message = abi.encodeCall(
            ERC721Gateway.receivePeggedToken,
            (address(originNft), predicted, user, user, tokenId, tokenMetadata, "ipfs://token-13")
        );
        _relayMessage(remoteGateway, address(nftGateway), 0, message);

        vm.prank(user);
        nftGateway.sendToken(predicted, recipient, tokenId);

        vm.expectRevert();
        ERC721PeggedToken(predicted).ownerOf(tokenId);
    }

    function test_receiveOriginToken_viaBridge_releasesEscrowedOrigin() public {
        uint256 tokenId = 17;
        originNft.mint(address(nftGateway), tokenId, "ipfs://origin-17");
        bytes memory message =
            abi.encodeCall(ERC721Gateway.receiveOriginToken, (address(originNft), user, recipient, tokenId));

        (bytes32 messageHash,,) = _relayMessage(remoteGateway, address(nftGateway), 0, message);

        assertEq(originNft.ownerOf(tokenId), recipient);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
    }

    function test_receivePeggedToken_wrongGatewaySender_marksFailed() public {
        bytes memory tokenMetadata = abi.encode("Mock NFT", "MNFT");
        bytes memory message = abi.encodeCall(
            ERC721Gateway.receivePeggedToken,
            (address(originNft), _predictedERC721Pegged(), user, recipient, 19, tokenMetadata, "ipfs://token-19")
        );

        (bytes32 messageHash,,) = _relayMessage(makeAddr("wrong-remote-gateway"), address(nftGateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_receivePeggedToken_wrongPredictedPeggedToken_marksFailed() public {
        bytes memory tokenMetadata = abi.encode("Mock NFT", "MNFT");
        bytes memory message = abi.encodeCall(
            ERC721Gateway.receivePeggedToken,
            (address(originNft), makeAddr("wrong-pegged"), user, recipient, 23, tokenMetadata, "ipfs://token-23")
        );

        (bytes32 messageHash,,) = _relayMessage(remoteGateway, address(nftGateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_sendToken_revertsWhenCallerDoesNotOwnPeggedToken() public {
        uint256 tokenId = 29;
        address predicted = _predictedERC721Pegged();
        bytes memory tokenMetadata = abi.encode("Mock NFT", "MNFT");
        bytes memory message = abi.encodeCall(
            ERC721Gateway.receivePeggedToken,
            (address(originNft), predicted, user, recipient, tokenId, tokenMetadata, "ipfs://token-29")
        );
        _relayMessage(remoteGateway, address(nftGateway), 0, message);

        vm.prank(user);
        vm.expectRevert(IERC721GatewayErrors.NotTokenOwner.selector);
        nftGateway.sendToken(predicted, recipient, tokenId);
    }

    function _deployERC721GatewayStack() internal {
        nftPeggedImplementation = new ERC721PeggedToken();

        ERC721TokenFactory factoryImpl = new ERC721TokenFactory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(ERC721TokenFactory.initialize, (admin, address(nftPeggedImplementation)))
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
        nftGateway.setOtherSide(
            remoteGateway, sourceChainId, address(nftPeggedImplementation), address(nftFactory), beacon
        );

        _registerGateway(address(nftGateway));
        _registerGateway(remoteGateway);

        recipient = address(new MockNFTReceiver());
        originNft = new MockERC721("Mock NFT", "MNFT");
    }

    function _predictedERC721Pegged() internal view returns (address) {
        return nftGateway.computeTokenAddress(address(nftGateway), address(originNft));
    }
}

contract ERC1155GatewayTest is GatewayBase {
    ERC1155Gateway internal multiGateway;
    ERC1155TokenFactory internal multiFactory;
    ERC1155PeggedToken internal multiPeggedImplementation;
    MockERC1155 internal originMulti;

    function setUp() public override {
        super.setUp();
        _deployBridge(0);
        _deployERC1155GatewayStack();
    }

    function test_receivePeggedTokens_viaBridge_deploysAndMints() public {
        address predicted = _predictedERC1155Pegged();
        bytes memory tokenMetadata = abi.encode("ipfs://collection/{id}.json");
        bytes memory message = abi.encodeCall(
            ERC1155Gateway.receivePeggedTokens, (address(originMulti), predicted, user, recipient, 1, 5, tokenMetadata)
        );

        _relayMessage(remoteGateway, address(multiGateway), 0, message);

        assertEq(multiGateway.getTokenMapping(predicted), address(originMulti));
        assertEq(ERC1155PeggedToken(predicted).balanceOf(recipient, 1), 5);
        assertEq(ERC1155PeggedToken(predicted).uri(1), "ipfs://collection/{id}.json");
    }

    function test_sendToken_originPath_escrowsOnGateway() public {
        originMulti.mint(user, 2, 10);
        vm.prank(user);
        originMulti.setApprovalForAll(address(multiGateway), true);

        vm.prank(user);
        multiGateway.sendToken(address(originMulti), recipient, 2, 4);

        assertEq(originMulti.balanceOf(address(multiGateway), 2), 4);
        assertEq(originMulti.balanceOf(user, 2), 6);
    }

    function test_sendBatchTokens_originPath_escrowsOnGateway() public {
        uint256[] memory ids = _pair(3, 4);
        uint256[] memory amounts = _pair(7, 8);
        originMulti.mintBatch(user, ids, amounts);
        vm.prank(user);
        originMulti.setApprovalForAll(address(multiGateway), true);

        vm.prank(user);
        multiGateway.sendBatchTokens(address(originMulti), recipient, ids, amounts);

        assertEq(originMulti.balanceOf(address(multiGateway), 3), 7);
        assertEq(originMulti.balanceOf(address(multiGateway), 4), 8);
    }

    function test_sendToken_peggedPath_burnsSupply() public {
        address predicted = _predictedERC1155Pegged();
        bytes memory tokenMetadata = abi.encode("ipfs://collection/{id}.json");
        bytes memory message = abi.encodeCall(
            ERC1155Gateway.receivePeggedTokens, (address(originMulti), predicted, user, user, 5, 9, tokenMetadata)
        );
        _relayMessage(remoteGateway, address(multiGateway), 0, message);

        vm.prank(user);
        multiGateway.sendToken(predicted, recipient, 5, 4);

        assertEq(ERC1155PeggedToken(predicted).balanceOf(user, 5), 5);
    }

    function test_receiveOriginBatchTokens_viaBridge_releasesEscrowedOrigin() public {
        uint256[] memory ids = _pair(6, 7);
        uint256[] memory amounts = _pair(2, 3);
        originMulti.mintBatch(address(multiGateway), ids, amounts);
        bytes memory message = abi.encodeCall(
            ERC1155Gateway.receiveOriginBatchTokens, (address(originMulti), user, recipient, ids, amounts)
        );

        (bytes32 messageHash,,) = _relayMessage(remoteGateway, address(multiGateway), 0, message);

        assertEq(originMulti.balanceOf(recipient, 6), 2);
        assertEq(originMulti.balanceOf(recipient, 7), 3);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
    }

    function test_receivePeggedBatchTokens_wrongGatewaySender_marksFailed() public {
        bytes memory tokenMetadata = abi.encode("ipfs://collection/{id}.json");
        bytes memory message = abi.encodeCall(
            ERC1155Gateway.receivePeggedBatchTokens,
            (address(originMulti), _predictedERC1155Pegged(), user, recipient, _pair(8, 9), _pair(1, 2), tokenMetadata)
        );

        (bytes32 messageHash,,) = _relayMessage(makeAddr("wrong-remote-gateway"), address(multiGateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_sendBatchTokens_revertsForLengthMismatch() public {
        uint256[] memory ids = _pair(1, 2);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;

        vm.prank(user);
        vm.expectRevert(IERC1155GatewayErrors.ArrayLengthMismatch.selector);
        multiGateway.sendBatchTokens(address(originMulti), recipient, ids, amounts);
    }

    function _deployERC1155GatewayStack() internal {
        multiPeggedImplementation = new ERC1155PeggedToken();

        ERC1155TokenFactory factoryImpl = new ERC1155TokenFactory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(ERC1155TokenFactory.initialize, (admin, address(multiPeggedImplementation)))
        );
        multiFactory = ERC1155TokenFactory(address(factoryProxy));

        ERC1155Gateway gatewayImpl = new ERC1155Gateway();
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(
            address(gatewayImpl),
            abi.encodeCall(ERC1155Gateway.initialize, (admin, address(bridge), address(multiFactory)))
        );
        multiGateway = ERC1155Gateway(payable(address(gatewayProxy)));

        vm.prank(admin);
        multiFactory.setPaymentGateway(address(multiGateway));

        address beacon = multiFactory.beacon();
        vm.prank(admin);
        multiGateway.setOtherSide(
            remoteGateway, sourceChainId, address(multiPeggedImplementation), address(multiFactory), beacon
        );

        _registerGateway(address(multiGateway));
        _registerGateway(remoteGateway);

        recipient = address(new MockNFTReceiver());
        originMulti = new MockERC1155("ipfs://origin/{id}.json");
    }

    function _predictedERC1155Pegged() internal view returns (address) {
        return multiGateway.computeTokenAddress(address(multiGateway), address(originMulti));
    }

    function _pair(uint256 a, uint256 b) internal pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = a;
        values[1] = b;
    }
}
