// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ERC1155Gateway} from "../../contracts/gateways/ERC1155Gateway.sol";
import {ERC1155TokenFactory} from "../../contracts/factories/ERC1155TokenFactory.sol";
import {ERC1155PeggedToken} from "../../contracts/tokens/ERC1155PeggedToken.sol";
import {MockERC1155Token} from "../mocks/MockERC1155.sol";
import {GatewayBase} from "./Base.t.sol";

contract ERC1155GatewayTest is GatewayBase {
    ERC1155Gateway internal nftGateway;
    ERC1155TokenFactory internal nftFactory;
    ERC1155PeggedToken internal nftImplementation;
    MockERC1155Token internal originNft;

    function setUp() public override {
        super.setUp();
        recipient = makeAddr("recipient");
        _deployBridge(0);
        _deployNftGatewayStack();
    }

    function test_sendToken_originPath_escrowsToken() public {
        originNft.mint(user, 7, 3);

        vm.prank(user);
        originNft.setApprovalForAll(address(nftGateway), true);
        vm.prank(user);
        nftGateway.sendToken(address(originNft), recipient, 7, 2, "");

        assertEq(originNft.balanceOf(address(nftGateway), 7), 2);
    }

    function test_receivePeggedToken_deploysAndMints() public {
        address predicted = nftGateway.computeTokenAddress(address(nftGateway), address(originNft));
        bytes memory metadata = abi.encode("ipfs://{id}.json");
        bytes memory message = abi.encodeCall(
            ERC1155Gateway.receivePeggedToken,
            (address(originNft), predicted, user, recipient, 7, 2, bytes(""), metadata)
        );

        _relayMessage(remoteGateway, address(nftGateway), 0, message);

        assertEq(nftGateway.getTokenMapping(predicted), address(originNft));
        assertEq(ERC1155PeggedToken(predicted).balanceOf(recipient, 7), 2);
        assertEq(ERC1155PeggedToken(predicted).uri(7), "ipfs://{id}.json");
    }

    function test_sendBatch_originPath_escrowsTokens() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 7;
        ids[1] = 8;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 2;
        amounts[1] = 3;
        originNft.mintBatch(user, ids, amounts);

        vm.prank(user);
        originNft.setApprovalForAll(address(nftGateway), true);
        vm.prank(user);
        nftGateway.sendBatch(address(originNft), recipient, ids, amounts, "");

        assertEq(originNft.balanceOf(address(nftGateway), 7), 2);
        assertEq(originNft.balanceOf(address(nftGateway), 8), 3);
    }

    function test_receiveOriginBatch_releasesEscrowedTokens() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 7;
        ids[1] = 8;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 2;
        amounts[1] = 3;
        originNft.mintBatch(address(nftGateway), ids, amounts);
        bytes memory message = abi.encodeCall(
            ERC1155Gateway.receiveOriginBatch, (address(originNft), user, recipient, ids, amounts, bytes(""))
        );

        _relayMessage(remoteGateway, address(nftGateway), 0, message);

        assertEq(originNft.balanceOf(recipient, 7), 2);
        assertEq(originNft.balanceOf(recipient, 8), 3);
    }

    function _deployNftGatewayStack() internal {
        nftImplementation = new ERC1155PeggedToken();
        ERC1155TokenFactory factoryImpl = new ERC1155TokenFactory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl), abi.encodeCall(ERC1155TokenFactory.initialize, (admin, address(nftImplementation)))
        );
        nftFactory = ERC1155TokenFactory(address(factoryProxy));

        ERC1155Gateway gatewayImpl = new ERC1155Gateway();
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(
            address(gatewayImpl),
            abi.encodeCall(ERC1155Gateway.initialize, (admin, address(bridge), address(nftFactory)))
        );
        nftGateway = ERC1155Gateway(payable(address(gatewayProxy)));

        vm.prank(admin);
        nftFactory.setPaymentGateway(address(nftGateway));
        address beacon = nftFactory.beacon();
        vm.prank(admin);
        nftGateway.setOtherSide(remoteGateway, sourceChainId, address(nftFactory), beacon);

        _registerGateway(address(nftGateway));
        _registerGateway(remoteGateway);

        originNft = new MockERC1155Token("ipfs://{id}.json");
    }
}
