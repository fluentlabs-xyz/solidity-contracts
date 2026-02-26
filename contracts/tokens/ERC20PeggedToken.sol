// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract ERC20PeggedToken is Initializable, ERC20Upgradeable, OwnableUpgradeable, PausableUpgradeable, ERC165Upgradeable {
    // we store symbol and name as strings
    string internal _symbol;
    string internal _name;

    /// @notice Token decimals (override of ERC20 default 18)
    uint8 private _decimals;
    /// @notice Origin token address on the origin chain
    address internal _originAddress;
    /// @notice Gateway address on the destination chain
    address internal _gateway;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(string memory name_, string memory symbol_, uint8 decimals_, address gateway, address originAddress) public initializer {
        // base ERC20 init; we override metadata below
        __ERC20_init("", "");
        __Ownable_init(msg.sender);
        __Pausable_init();
        __ERC165_init();

        _symbol = symbol_;
        _name = name_;
        _originAddress = originAddress;
        _gateway = gateway;
        _decimals = decimals_;
    }

    function getOrigin() public view returns (address, address) {
        return (_gateway, _originAddress);
    }

    /// @notice Mint tokens; restricted to owner (bridge / gateway).
    function mint(address account, uint256 amount) external onlyOwner {
        _mint(account, amount);
    }

    /// @notice Burn tokens; restricted to owner (bridge / gateway).
    function burn(address account, uint256 amount) external onlyOwner {
        _burn(account, amount);
    }

    /// @notice Pause all token transfers, mints, and burns.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause token transfers, mints, and burns.
    function unpause() external onlyOwner {
        _unpause();
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @dev Enforce pause semantics for all balance updates (transfer / mint / burn).
    function _update(address from, address to, uint256 value) internal virtual override whenNotPaused {
        super._update(from, to, value);
    }

    /// @dev ERC165 interface support (IERC20 + IERC20Metadata).
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165Upgradeable) returns (bool) {
        return
            interfaceId == type(IERC20).interfaceId || interfaceId == type(IERC20Metadata).interfaceId || super.supportsInterface(interfaceId);
    }
}
