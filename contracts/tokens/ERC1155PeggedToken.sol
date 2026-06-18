// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract ERC1155PeggedToken is ERC1155Upgradeable, Ownable2StepUpgradeable, PausableUpgradeable {
    error TokenPaused();

    bytes32 private constant ERC1155_PEGGED_TOKEN_STORAGE_LOCATION =
        0xb82797d75c7c062b76ad0fe8bb9012f87a748efbd41afad54599493429bf8200;

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

    function initialize(string memory uri_, address originAddress_) public initializer {
        __ERC1155_init(uri_);
        __Ownable_init(msg.sender);
        __Ownable2Step_init();
        __Pausable_init();
        _getERC1155PeggedTokenStorage()._originAddress = originAddress_;
    }

    function originAddress() external view returns (address) {
        return _getERC1155PeggedTokenStorage()._originAddress;
    }

    function mint(address to, uint256 id, uint256 amount, bytes calldata data) external onlyOwner {
        _mint(to, id, amount, data);
    }

    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts, bytes calldata data)
        external
        onlyOwner
    {
        _mintBatch(to, ids, amounts, data);
    }

    function burn(address from, uint256 id, uint256 amount) external onlyOwner {
        _burn(from, id, amount);
    }

    function burnBatch(address from, uint256[] calldata ids, uint256[] calldata amounts) external onlyOwner {
        _burnBatch(from, ids, amounts);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        if (paused()) revert TokenPaused();
        super._update(from, to, ids, values);
    }
}
