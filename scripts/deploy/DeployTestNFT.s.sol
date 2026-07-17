// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {MockERC721} from "../../test/mocks/MockERC721.sol";
import {MockERC1155URIStorage} from "../../contracts/mocks/MockERC1155URIStorage.sol";

/// @notice Deploys two test NFT collections (ERC-721 + ERC-1155) on Ethereum Sepolia and mints a spread
///         of tokens to one recipient, for manual testing of the NFT bridge UI.
///
/// @dev Metadata is NOT self-hosted: token URIs point at an existing public collection (BAYC, decimal-indexed
///      ipfs:// paths) so Sepolia Blockscout resolves `image_url` on its own. Two ERC-721 tokens get a
///      broken/empty URI to exercise the frontend placeholder.
///
/// Phases: (1) validate chain + recipient, (2) broadcast deploy + mint, (3) write manifest JSON.
///
/// Environment:
/// - RECIPIENT (optional, default 0xd672A015b604a70737cAaEc6d07a6dFB04467a84) receives all minted tokens.
/// - OUTPUT_PATH (optional, default deployments/testnet/sepolia.test-nft.json) receives the manifest.
///
/// Run:
///   forge script scripts/deploy/DeployTestNFT.s.sol:DeployTestNFT --rpc-url sepolia --broadcast -vvvv
contract DeployTestNFT is Script {
    uint256 private constant SEPOLIA_CHAIN_ID = 11155111;

    // BAYC metadata, decimal-indexed: <base><id> -> JSON with name + ipfs:// image.
    // ipfs:// scheme keeps metadata AND image gateway-agnostic (Blockscout resolves via its own gateway).
    string private constant ERC721_BASE = "ipfs://QmeSjSinHpPnmXmspMjwiXyN6zS4E9zccariGR3jxcaWtq/";
    string private constant ERC1155_BASE = "ipfs://QmeSjSinHpPnmXmspMjwiXyN6zS4E9zccariGR3jxcaWtq/";

    function run() external {
        // Phase 1: validate.
        require(block.chainid == SEPOLIA_CHAIN_ID, "expected Sepolia (11155111)");
        address recipient = vm.envOr("RECIPIENT", address(0xd672A015b604a70737cAaEc6d07a6dFB04467a84));
        require(recipient != address(0), "RECIPIENT required");
        string memory outputPath =
            vm.envOr("OUTPUT_PATH", string("deployments/testnet/sepolia.test-nft.json"));

        console2.log("Deploying test NFT collections");
        console2.log("  recipient:", recipient);
        console2.log("  outputPath:", outputPath);

        // Phase 2: deploy + mint.
        vm.startBroadcast();
        MockERC721 erc721 = new MockERC721("Fluent Test Apes", "FTAPE");
        MockERC1155URIStorage erc1155 = new MockERC1155URIStorage();

        _mintERC721(erc721, recipient);
        _mintERC1155(erc1155, recipient);
        vm.stopBroadcast();

        // Phase 3: write manifest.
        _writeManifest(outputPath, address(erc721), address(erc1155), recipient);

        console2.log("ERC721  (Fluent Test Apes):", address(erc721));
        console2.log("ERC1155 (per-id URIs):", address(erc1155));
    }

    /// @dev 15 tokens; ids 14 & 15 get empty/broken URIs to exercise the placeholder.
    function _mintERC721(MockERC721 erc721, address to) internal {
        for (uint256 id = 1; id <= 13; id++) {
            erc721.mint(to, id, string.concat(ERC721_BASE, vm.toString(id)));
        }
        erc721.mint(to, 14, ""); // empty URI
        erc721.mint(to, 15, "ipfs://broken/does-not-exist.json"); // unresolvable URI
    }

    /// @dev 11 ids with varied balances: several 1s, a 3 and a 5, one ~100, one ~1000.
    function _mintERC1155(MockERC1155URIStorage erc1155, address to) internal {
        uint256[11] memory ids = [uint256(1), 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
        uint256[11] memory amounts = [uint256(1), 1, 1, 1, 3, 5, 100, 1000, 1, 2, 4];
        for (uint256 i = 0; i < ids.length; i++) {
            erc1155.mint(to, ids[i], amounts[i], string.concat(ERC1155_BASE, vm.toString(ids[i])));
        }
    }

    function _writeManifest(string memory outputPath, address erc721, address erc1155, address recipient) internal {
        string memory out = vm.serializeUint("test-nft", "chainId", block.chainid);
        out = vm.serializeAddress("test-nft", "erc721", erc721);
        out = vm.serializeAddress("test-nft", "erc1155", erc1155);
        out = vm.serializeAddress("test-nft", "recipient", recipient);
        vm.writeJson(out, outputPath);
    }
}
