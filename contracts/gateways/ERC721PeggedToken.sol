// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC721URIStorageUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

/**
 * @title ERC721PeggedToken
 * @author Fluent Labs
 * @notice Pegged ERC721 collection behind an UpgradeableBeacon proxy; mint/burn restricted to owner (gateway).
 */
contract ERC721PeggedToken is Initializable, ERC721URIStorageUpgradeable, Ownable2StepUpgradeable, PausableUpgradeable {
    error TokenPaused();
    error BurnFromWrongOwner();

    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.ERC721PeggedTokenStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC721_PEGGED_TOKEN_STORAGE_LOCATION =
        0x945d6f58d840a6d6acaa3352affe722ee290d9f402438f20ba4d44b2174c1f00;

    /// @custom:storage-location erc7201:fluent.storage.ERC721PeggedTokenStorage
    struct ERC721PeggedTokenStorage {
        address _originAddress;
        uint256[50] __gap;
    }

    function _getERC721PeggedTokenStorage() private pure returns (ERC721PeggedTokenStorage storage $) {
        assembly ("memory-safe") {
            $.slot := ERC721_PEGGED_TOKEN_STORAGE_LOCATION
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(string memory name_, string memory symbol_, address originTokenAddr) public initializer {
        __ERC721_init(name_, symbol_);
        __ERC721URIStorage_init();
        __Ownable_init(msg.sender);
        __Ownable2Step_init();
        __Pausable_init();

        ERC721PeggedTokenStorage storage $ = _getERC721PeggedTokenStorage();
        $._originAddress = originTokenAddr;
    }

    function originAddress() public view returns (address) {
        return _getERC721PeggedTokenStorage()._originAddress;
    }

    function mint(address to, uint256 tokenId, string memory tokenURI_) external onlyOwner {
        _safeMint(to, tokenId);
        if (bytes(tokenURI_).length > 0) {
            _setTokenURI(tokenId, tokenURI_);
        }
    }

    function burn(address from, uint256 tokenId) external onlyOwner {
        if (ownerOf(tokenId) != from) revert BurnFromWrongOwner();
        _burn(tokenId);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        if (paused()) revert TokenPaused();
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721URIStorageUpgradeable) returns (bool) {
        return interfaceId == type(IERC721).interfaceId || interfaceId == type(IERC721Metadata).interfaceId || super.supportsInterface(interfaceId);
    }
}
