// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IUniversalToken} from "../interfaces/IUniversalToken.sol";

/**
 * @title UniversalToken
 * @author Fluent Labs
 * @notice Solidity implementation of Universal Token Standard (ERC20-compatible)
 * @dev Implements IUniversalToken interface to match ERC20Token pattern
 */
contract UniversalToken is IUniversalToken {
    /// @notice Token name
    string private _name;
    /// @notice Token symbol
    string private _symbol;
    /// @notice Token decimals
    uint8 private _decimals;
    /// @notice Total token supply
    uint256 private _totalSupply;

    /// @notice Mapping from address to balance
    mapping(address => uint256) private _balances;
    /// @notice Mapping from owner to spender to allowance
    mapping(address => mapping(address => uint256)) private _allowances;

    /// @notice Optional minter address (if set, enables minting)
    address private _minter;
    /// @notice Optional pauser address (if set, enables pause/unpause)
    address private _pauser;
    /// @notice Paused state (true if transfers are paused)
    bool private _paused;

    /*******
     * Modifiers
     ************/

    modifier onlyMinter() {
        require(msg.sender == _minter, MinterMismatch(msg.sender, _minter));
        _;
    }

    modifier whenNotPaused() {
        require(!_paused, EnforcedPause());
        _;
    }

    modifier onlyWhenNotPaused() {
        require(!_paused, EnforcedPause());
        _;
    }

    modifier onlyPauser() {
        require(msg.sender == _pauser, PauserMismatch(msg.sender, _pauser));
        _;
    }

    modifier onlyWhenPaused() {
        require(_paused, ExpectedPause());
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
    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 initialSupply_, address minter_, address pauser_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
        _minter = minter_;
        _pauser = pauser_;
        _paused = false;

        if (initialSupply_ > 0) _mint(msg.sender, initialSupply_);
    }

    /**
     * @notice Returns the name of the token
     * @return Token name
     */
    function name() external view override returns (string memory) {
        return _name;
    }

    /**
     * @notice Returns the symbol of the token
     * @return Token symbol
     */
    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    /**
     * @notice Returns the decimals of the token
     * @return Number of decimals
     */
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice Returns the total supply of the token
     * @return Total token supply
     */
    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @notice Returns the balance of an account
     * @param account Address to query
     * @return Token balance
     */
    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    /**
     * @notice Transfers tokens to a recipient
     * @param to Recipient address
     * @param amount Amount to transfer
     * @return success True if transfer succeeded
     */
    function transfer(address to, uint256 amount) external override returns (bool success) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice Transfers tokens from one address to another (requires approval)
     * @param from Source address
     * @param to Recipient address
     * @param amount Amount to transfer
     * @return success True if transfer succeeded
     */
    function transferFrom(address from, address to, uint256 amount) external override returns (bool success) {
        address spender = msg.sender;

        // Check and update allowance
        uint256 currentAllowance = _allowances[from][spender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) {
                revert InsufficientAllowance(from, spender, currentAllowance, amount);
            }
            unchecked {
                _allowances[from][spender] = currentAllowance - amount;
            }
        }

        _transfer(from, to, amount);
        return true;
    }

    /**
     * @notice Approves a spender to transfer tokens on behalf of the caller
     * @param spender Address to approve
     * @param amount Amount to approve
     * @return success True if approval succeeded
     */
    function approve(address spender, uint256 amount) external override returns (bool success) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Returns the allowance of a spender for an owner
     * @param owner Token owner
     * @param spender Approved spender
     * @return allowance Approved amount
     */
    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @notice Mints tokens to an address (only if minter is set)
     * @param to Recipient address
     * @param amount Amount to mint
     * @return success True if mint succeeded
     */
    function mint(address to, uint256 amount) external override onlyMinter whenNotPaused returns (bool success) {
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
     * @return success True if pause succeeded
     */
    function pause() external override onlyPauser onlyWhenNotPaused returns (bool success) {
        _paused = true;
        emit Paused(msg.sender);
        return true;
    }

    /**
     * @notice Unpauses token transfers (only if pauser is set)
     * @return success True if unpause succeeded
     */
    function unpause() external override onlyPauser onlyWhenPaused returns (bool success) {
        _paused = false;
        emit Unpaused(msg.sender);
        return true;
    }

    /**
     * @notice Internal function to transfer tokens
     * @param from Source address
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function _transfer(address from, address to, uint256 amount) internal whenNotPaused {
        require(from != address(0), InvalidSender(from));
        require(to != address(0), InvalidReceiver(to));

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, InsufficientBalance(from, fromBalance, amount));

        unchecked {
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }

        emit Transfer(from, to, amount);
    }

    /**
     * @notice Internal function to approve spending
     * @param owner Token owner
     * @param spender Approved spender
     * @param amount Amount to approve
     */
    function _approve(address owner, address spender, uint256 amount) internal {
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _mint(address to, uint256 amount) internal {
        _totalSupply += amount;
        unchecked {
            _balances[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        require(from != address(0), InvalidSender(from));
        require(_balances[from] >= amount, InsufficientBalance(from, _balances[from], amount));
        _totalSupply -= amount;
        _balances[from] = _balances[from] - amount;
        emit Transfer(from, address(0), amount);
    }
}
