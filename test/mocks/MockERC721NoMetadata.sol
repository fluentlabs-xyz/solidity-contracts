// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {MockERC721} from "./MockERC721.sol";

/// @notice ERC-721 whose OPTIONAL metadata extension reverts, to exercise the
///         gateway's guarded name/symbol reads.
contract MockERC721NoMetadata is MockERC721 {
    constructor() MockERC721("", "") {}

    function name() public pure override returns (string memory) {
        revert("no metadata");
    }

    function symbol() public pure override returns (string memory) {
        revert("no metadata");
    }
}
