// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {ERC1155URIStorage} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155URIStorage.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

/// @notice Test ERC-1155 collection with per-id metadata URIs.
/// @dev Unlike {MockERC1155} (single `{id}`-templated base URI), each id stores its own full URI so an
///      explorer can resolve distinct metadata/image per id. `uri(id)` is what the NFT bridge carries.
contract MockERC1155URIStorage is ERC1155URIStorage {
    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 amount, string memory tokenURI_) external {
        _mint(to, id, amount, "");
        _setURI(id, tokenURI_);
    }
}
