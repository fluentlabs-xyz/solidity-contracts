// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockERC721Token is ERC721 {
    mapping(uint256 => string) private _tokenURIs;

    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) {}

    function mint(address to, uint256 tokenId, string memory tokenURI_) external {
        _mint(to, tokenId);
        _tokenURIs[tokenId] = tokenURI_;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return _tokenURIs[tokenId];
    }
}
