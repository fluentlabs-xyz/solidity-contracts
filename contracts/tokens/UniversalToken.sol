// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IUniversalTokenErrorCodes} from "../interfaces/IUniversalToken.sol";

/**
 * @title UniversalToken
 * @author Fluent Labs
 * @notice It's a Solidity implementation of the Universal Token Standard precompile of Fluent Chain.
 * @dev Inherits from OpenZeppelin ERC20; implements IUniversalToken ABI (minter, pauser, custom decimals).
 *      Uses IUniversalTokenErrorCodes for custom errors only to avoid duplicate Transfer/Approval events with IERC20.
 */
contract UniversalToken is ERC20, Pausable, IUniversalTokenErrorCodes {
    /// @notice Token decimals (override of ERC20 default 18)
    uint8 private _decimals;
    /// @notice Optional minter address (if set, enables minting)
    address private _minter;
    /// @notice Optional pauser address (if set, enables pause/unpause)
    address private _pauser;

    /*******
     * Modifiers
     ************/

    modifier onlyPauser() {
        require(msg.sender == _pauser, PauserMismatch(msg.sender, _pauser));
        _;
    }

    modifier onlyMinter() {
        require(msg.sender == _minter, MinterMismatch(msg.sender, _minter));
        _;
    }

    /**
     * @notice Constructor - initializes the token
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param decimals_ Number of decimals
     * @param initialSupply_ Initial supply to mint to deployer
     * @param minter_ Optional minter address (address(0) if not mintable)
     * @param pauser_ Optional pauser address (address(0) if not pausable)
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 initialSupply_,
        address minter_,
        address pauser_
    ) ERC20(name_, symbol_) {
        _decimals = decimals_;
        _minter = minter_;
        _pauser = pauser_;

        if (initialSupply_ > 0) _mint(msg.sender, initialSupply_);
    }

    /**
     * @notice Mints tokens to an address (only if minter is set)
     * @param to Recipient address
     * @param amount Amount to mint
     * @return success True if mint succeeded
     */
    function mint(address to, uint256 amount) external onlyMinter whenNotPaused returns (bool success) {
        _mint(to, amount);
        return true;
    }

    /**
     * @notice Burns tokens from an address (only if minter is set)
     * @param from Source address
     * @param amount Amount to burn
     * @return success True if burn succeeded
     */
    function burn(address from, uint256 amount) external onlyMinter whenNotPaused returns (bool success) {
        _burn(from, amount);
        return true;
    }

    /**
     * @notice Pauses token transfers (only if pauser is set)
     */
    function pause() external onlyPauser {
        _pause();
    }

    /**
     * @notice Unpauses token transfers (only if pauser is set)
     */
    function unpause() external onlyPauser {
        _unpause();
    }

    /// @dev Enforce pause for all balance-changing operations (transfer, mint, burn).
    function _update(address from, address to, uint256 value) internal virtual override whenNotPaused {
        super._update(from, to, value);
    }
}
