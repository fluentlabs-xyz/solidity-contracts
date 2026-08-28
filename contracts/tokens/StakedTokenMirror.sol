// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/**
 * @title StakedTokenMirror
 * @author Fluent Labs
 *
 * @notice L1 mirror representation of canonical L2 ERC-4626 vault shares.
 * @dev Mint and burn are restricted to the owner, expected to be the L1 {StakingGateway}.
 *      Yield accounting is not performed here; this token is only a bridged representation
 *      of canonical L2 shares locked in the L2 staking gateway.
 */
contract StakedTokenMirror is Initializable, ERC20Upgradeable, Ownable2StepUpgradeable, PausableUpgradeable {
    /// @notice Required address parameter is the zero address.
    error ZeroAddressNotAllowed(string field);

    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.StakedTokenMirrorStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STAKED_TOKEN_MIRROR_STORAGE_LOCATION =
        0x87856ac4dca3da3bedd0b8bf374aacc3d567e869eba2889850c14b8e96f78700;

    /// @custom:storage-location erc7201:Fluent.storage.StakedTokenMirrorStorage
    struct StakedTokenMirrorStorage {
        uint8 _decimals;
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256[50] __gap;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address initialOwner
    ) external initializer {
        require(initialOwner != address(0), ZeroAddressNotAllowed("initialOwner"));

        __ERC20_init(name_, symbol_);
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __Pausable_init();

        _getStorage()._decimals = decimals_;
    }

    function mint(address account, uint256 amount) external onlyOwner {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external onlyOwner {
        _burn(account, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function decimals() public view override returns (uint8) {
        return _getStorage()._decimals;
    }

    function _update(address from, address to, uint256 value) internal override whenNotPaused {
        super._update(from, to, value);
    }

    function _getStorage() private pure returns (StakedTokenMirrorStorage storage $) {
        assembly ("memory-safe") {
            $.slot := STAKED_TOKEN_MIRROR_STORAGE_LOCATION
        }
    }
}
