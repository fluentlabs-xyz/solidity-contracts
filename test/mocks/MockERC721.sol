// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockERC721 is ERC721URIStorage {
    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) {}

    function mint(address to, uint256 tokenId, string memory tokenURI_) external {
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, tokenURI_);
    }
}
