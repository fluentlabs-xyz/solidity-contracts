// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    ERC1155URIStorageUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155URIStorageUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/**
 * @title ERC1155PeggedToken
 * @notice Pegged ERC-1155 collection minted and burned by its gateway.
 */
contract ERC1155PeggedToken is
    Initializable,
    ERC1155URIStorageUpgradeable,
    Ownable2StepUpgradeable,
    PausableUpgradeable
{
    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.ERC1155PeggedTokenStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC1155_PEGGED_TOKEN_STORAGE_LOCATION =
        0x49de27c08259ed6ec910f3dd825f83e7c2a4d922574d7d9ab766bf95d64d7e00;

    /// @custom:storage-location erc7201:fluent.storage.ERC1155PeggedTokenStorage
    struct ERC1155PeggedTokenStorage {
        address _originAddress;
        uint256[50] __gap;
    }

    function _getERC1155PeggedTokenStorage() private pure returns (ERC1155PeggedTokenStorage storage $) {
        assembly ("memory-safe") {
            $.slot := ERC1155_PEGGED_TOKEN_STORAGE_LOCATION
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address originAddress_) public initializer {
        __ERC1155_init("");
        __ERC1155URIStorage_init();
        __Ownable_init(msg.sender);
        __Ownable2Step_init();
        __Pausable_init();
        _getERC1155PeggedTokenStorage()._originAddress = originAddress_;
    }

    function originAddress() external view returns (address) {
        return _getERC1155PeggedTokenStorage()._originAddress;
    }

    function mint(address to, uint256 id, uint256 amount, string memory uri_) external onlyOwner {
        _mint(to, id, amount, "");
        if (bytes(uri_).length > 0) _setURI(id, uri_);
    }

    function mintBatch(address to, uint256[] memory ids, uint256[] memory amounts, string[] memory uris)
        external
        onlyOwner
    {
        _mintBatch(to, ids, amounts, "");
        for (uint256 i = 0; i < ids.length; i++) {
            if (bytes(uris[i]).length > 0) _setURI(ids[i], uris[i]);
        }
    }

    function burn(address from, uint256 id, uint256 amount) external onlyOwner {
        _burn(from, id, amount);
    }

    function burnBatch(address from, uint256[] memory ids, uint256[] memory amounts) external onlyOwner {
        _burnBatch(from, ids, amounts);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override
        whenNotPaused
    {
        super._update(from, to, ids, values);
    }
}
