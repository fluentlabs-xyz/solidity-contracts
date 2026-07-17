// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    ERC721URIStorageUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/**
 * @title ERC721PeggedToken
 * @notice Pegged ERC-721 collection minted and burned by its gateway.
 */
contract ERC721PeggedToken is Initializable, ERC721URIStorageUpgradeable, Ownable2StepUpgradeable, PausableUpgradeable {
    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.ERC721PeggedTokenStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC721_PEGGED_TOKEN_STORAGE_LOCATION =
        0x2884239c88dc873f64daf8ca68746cb91de29a3dbd00d1e0e683fcfdc5cb8a00;

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

    function initialize(string memory name_, string memory symbol_, address originAddress_) public initializer {
        __ERC721_init(name_, symbol_);
        __ERC721URIStorage_init();
        __Ownable_init(msg.sender);
        __Ownable2Step_init();
        __Pausable_init();
        _getERC721PeggedTokenStorage()._originAddress = originAddress_;
    }

    function originAddress() external view returns (address) {
        return _getERC721PeggedTokenStorage()._originAddress;
    }

    function mint(address to, uint256 tokenId, string memory tokenURI_) external onlyOwner {
        _safeMint(to, tokenId);
        if (bytes(tokenURI_).length > 0) _setTokenURI(tokenId, tokenURI_);
    }

    function burn(uint256 tokenId) external onlyOwner {
        _burn(tokenId);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _update(address to, uint256 tokenId, address auth) internal override whenNotPaused returns (address) {
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721URIStorageUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
