// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract ERC721PeggedToken is ERC721Upgradeable, Ownable2StepUpgradeable, PausableUpgradeable {
    error TokenPaused();
    error NotTokenOwner();

    bytes32 private constant ERC721_PEGGED_TOKEN_STORAGE_LOCATION =
        0x4dc50d546f55c7361419ad68b44e3ee6b4e053813a314ec38494e5dc981fa000;

    struct ERC721PeggedTokenStorage {
        address _originAddress;
        mapping(uint256 => string) _tokenURIs;
        uint256[49] __gap;
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
        __Ownable_init(msg.sender);
        __Ownable2Step_init();
        __Pausable_init();
        _getERC721PeggedTokenStorage()._originAddress = originAddress_;
    }

    function originAddress() external view returns (address) {
        return _getERC721PeggedTokenStorage()._originAddress;
    }

    function mint(address to, uint256 tokenId, string calldata tokenURI_) external onlyOwner {
        _safeMint(to, tokenId);
        if (bytes(tokenURI_).length != 0) {
            _getERC721PeggedTokenStorage()._tokenURIs[tokenId] = tokenURI_;
        }
    }

    function burn(address from, uint256 tokenId) external onlyOwner {
        require(ownerOf(tokenId) == from, NotTokenOwner());
        _burn(tokenId);
        delete _getERC721PeggedTokenStorage()._tokenURIs[tokenId];
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        string memory stored = _getERC721PeggedTokenStorage()._tokenURIs[tokenId];
        if (bytes(stored).length != 0) return stored;
        return super.tokenURI(tokenId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (paused()) revert TokenPaused();
        return super._update(to, tokenId, auth);
    }
}
