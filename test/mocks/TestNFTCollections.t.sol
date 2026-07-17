// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC721} from "./MockERC721.sol";
import {MockERC1155URIStorage} from "../../contracts/mocks/MockERC1155URIStorage.sol";

contract TestNFTCollections is Test {
    address constant TO = 0xd672A015b604a70737cAaEc6d07a6dFB04467a84;

    function test_erc721() public {
        MockERC721 c = new MockERC721("Fluent Test Apes", "FTAPE");
        assertTrue(c.supportsInterface(0x80ac58cd));
        for (uint256 id = 1; id <= 13; id++) {
            c.mint(TO, id, string.concat("https://base/", vm.toString(id)));
        }
        c.mint(TO, 14, "");
        c.mint(TO, 15, "ipfs://broken/does-not-exist.json");
        assertEq(c.balanceOf(TO), 15);
        assertEq(c.tokenURI(1), "https://base/1");
        assertEq(c.tokenURI(14), "");
        assertEq(c.tokenURI(15), "ipfs://broken/does-not-exist.json");
    }

    function test_erc1155() public {
        MockERC1155URIStorage c = new MockERC1155URIStorage();
        assertTrue(c.supportsInterface(0xd9b67a26));
        c.mint(TO, 7, 100, "https://base/7");
        c.mint(TO, 8, 1000, "https://base/8");
        assertEq(c.balanceOf(TO, 7), 100);
        assertEq(c.balanceOf(TO, 8), 1000);
        assertEq(c.uri(7), "https://base/7");
        assertEq(c.uri(8), "https://base/8");
    }
}
