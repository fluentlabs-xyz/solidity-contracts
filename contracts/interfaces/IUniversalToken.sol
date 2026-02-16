// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IUniversalTokenErrorCodes {
    /// @notice Error thrown when operation is attempted while paused
    error EnforcedPause();

    /// @notice Error thrown when pause is expected but contract is not paused
    error ExpectedPause();

    /// @notice Error thrown when sender is invalid (zero address)
    error InvalidSender(address sender);

    /// @notice Error thrown when receiver is invalid (zero address)
    error InvalidReceiver(address receiver);

    /// @notice Error thrown when balance is insufficient
    error InsufficientBalance(address account, uint256 balance, uint256 required);

    /// @notice Error thrown when allowance is insufficient
    error InsufficientAllowance(address owner, address spender, uint256 allowance, uint256 required);

    /// @notice Error thrown when minting is not enabled
    error NotMintable();

    /// @notice Error thrown when caller is not the minter
    error MinterMismatch(address caller, address minter);

    /// @notice Error thrown when pausing is not enabled
    error NotPausable();

    /// @notice Error thrown when caller is not the pauser
    error PauserMismatch(address caller, address pauser);
}

/**
 * @title IUniversalToken
 * @notice Interface for Universal Tokens (ERC20-compatible)
 * @dev Universal Tokens use a precompile/runtime pattern
 */
interface IUniversalToken is IUniversalTokenErrorCodes {
    /// @notice Emitted when tokens are transferred
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Emitted when allowance is set
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Emitted when contract is paused
    event Paused(address indexed account);

    /// @notice Emitted when contract is unpaused
    event Unpaused(address indexed account);

    /**
     * @notice Returns the name of the token
     * @return name Token name
     */
    function name() external view returns (string memory name);

    /**
     * @notice Returns the symbol of the token
     * @return symbol Token symbol
     */
    function symbol() external view returns (string memory symbol);

    /**
     * @notice Returns the decimals of the token
     * @return decimals Number of decimals
     */
    function decimals() external view returns (uint8 decimals);

    /**
     * @notice Returns the total supply of the token
     * @return totalSupply Total token supply
     */
    function totalSupply() external view returns (uint256 totalSupply);

    /**
     * @notice Returns the balance of an account
     * @param account Address to query
     * @return balance Token balance
     */
    function balanceOf(address account) external view returns (uint256 balance);

    /**
     * @notice Transfers tokens to a recipient
     * @param to Recipient address
     * @param amount Amount to transfer
     * @return success True if transfer succeeded
     */
    function transfer(address to, uint256 amount) external returns (bool success);

    /**
     * @notice Transfers tokens from one address to another (requires approval)
     * @param from Source address
     * @param to Recipient address
     * @param amount Amount to transfer
     * @return success True if transfer succeeded
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool success);

    /**
     * @notice Approves a spender to transfer tokens on behalf of the caller
     * @param spender Address to approve
     * @param amount Amount to approve
     * @return success True if approval succeeded
     */
    function approve(address spender, uint256 amount) external returns (bool success);

    /**
     * @notice Returns the allowance of a spender for an owner
     * @param owner Token owner
     * @param spender Approved spender
     * @return allowance Approved amount
     */
    function allowance(address owner, address spender) external view returns (uint256 allowance);

    /**
     * @notice Mints tokens to an address (only if minter is set)
     * @param to Recipient address
     * @param amount Amount to mint
     * @return success True if mint succeeded
     */
    function mint(address to, uint256 amount) external returns (bool success);

    /**
     * @notice Pauses token transfers (only if pauser is set)
     * @return success True if pause succeeded
     */
    function pause() external returns (bool success);

    /**
     * @notice Unpauses token transfers (only if pauser is set)
     * @return success True if unpause succeeded
     */
    function unpause() external returns (bool success);
}
