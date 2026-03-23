// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title ERC20PeggedToken
 * @dev Pegged ERC20 representation deployed behind a UpgradeableBeacon proxy.
 *      Mint and burn are restricted to the owner (gateway). Supports pause via {PausableUpgradeable}.
 *      Metadata (name, symbol, decimals) is set once during {initialize} and stored locally
 *      rather than using the default ERC20 storage, allowing custom values per pegged token.
 */
contract ERC20PeggedToken is Initializable, ERC20Upgradeable, OwnableUpgradeable, PausableUpgradeable, ERC165Upgradeable {
    /// @notice Token transfer attempted while paused.
    error TokenPaused();

    // ============ Storage ============

    /// @dev Locally stored symbol (overrides ERC20Upgradeable).
    string internal _symbol;
    /// @dev Locally stored name (overrides ERC20Upgradeable).
    string internal _name;

    /// @dev Token decimals (overrides ERC20 default of 18).
    uint8 private _decimals;
    /// @dev Address of the original token on the source chain.
    address internal _originAddress;
    /// @dev Gateway that owns this token (authorized to mint/burn).
    address internal _gateway;

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Prevent the implementation contract from being initialized directly
        _disableInitializers();
    }

    // ============ Initializer ============

    /** @notice Initializes the pegged token with metadata and gateway ownership. */
    function initialize(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address gateway,
        address originAddress
    ) public initializer {
        // Pass empty strings because name/symbol are stored locally below,
        // overriding the default ERC20 storage to support custom per-token metadata
        __ERC20_init("", "");
        // The deployer (msg.sender) becomes the initial owner; ownership is
        // later transferred to the gateway if needed
        __Ownable_init(msg.sender);
        __Pausable_init();
        __ERC165_init();

        // Store metadata locally so each pegged token can have distinct values
        // even though they share the same implementation via the beacon proxy
        _symbol = symbol_;
        _name = name_;
        // Track the L1 origin address so the bridge can map back during withdrawals
        _originAddress = originAddress;
        // Gateway is the only address authorized to mint/burn via onlyOwner
        _gateway = gateway;
        // Decimals may differ from the default 18 to match the origin token's precision
        _decimals = decimals_;
    }

    // ============ Views ============

    /** @notice Returns the gateway address and the origin token address on the source chain. */
    function getOrigin() public view returns (address, address) {
        // Returns (gateway, L1 token address) so the bridge can resolve the mapping
        return (_gateway, _originAddress);
    }

    // ============ Mint / Burn ============

    /// @notice Mint tokens; restricted to owner (bridge / gateway).
    function mint(address account, uint256 amount) external onlyOwner {
        // Only the gateway can mint — called when L1 tokens are deposited into the bridge
        _mint(account, amount);
    }

    /// @notice Burn tokens; restricted to owner (bridge / gateway).
    function burn(address account, uint256 amount) external onlyOwner {
        // Only the gateway can burn — called when L2 tokens are withdrawn back to L1
        _burn(account, amount);
    }

    // ============ Pause ============

    /// @notice Pause all token transfers, mints, and burns.
    function pause() external onlyOwner {
        // Emergency circuit breaker — halts all transfers, mints, and burns via _update hook
        _pause();
    }

    /// @notice Unpause token transfers, mints, and burns.
    function unpause() external onlyOwner {
        // Resumes normal operations after an emergency pause
        _unpause();
    }

    /// @inheritdoc ERC20Upgradeable
    function name() public view override returns (string memory) {
        // Return the locally stored name instead of the empty ERC20 default
        return _name;
    }

    /// @inheritdoc ERC20Upgradeable
    function symbol() public view override returns (string memory) {
        // Return the locally stored symbol instead of the empty ERC20 default
        return _symbol;
    }

    /// @inheritdoc ERC20Upgradeable
    function decimals() public view override returns (uint8) {
        // Return the locally stored decimals to match the origin token's precision
        return _decimals;
    }

    // ============ Hooks ============

    /// @dev Enforce pause semantics for all balance updates (transfer / mint / burn).
    function _update(address from, address to, uint256 value) internal virtual override {
        // Guard all balance mutations (transfer, mint, burn) against the paused state
        // This is checked before super._update to avoid partial state changes
        if (paused()) {
            revert TokenPaused();
        }
        // Delegate to ERC20Upgradeable for the actual balance bookkeeping
        super._update(from, to, value);
    }

    // ============ ERC165 ============

    /// @dev ERC165 interface support (IERC20 + IERC20Metadata).
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165Upgradeable) returns (bool) {
        // Advertise IERC20 and IERC20Metadata so callers can introspect token capabilities
        // super.supportsInterface handles ERC165 itself
        return
            interfaceId == type(IERC20).interfaceId || interfaceId == type(IERC20Metadata).interfaceId || super.supportsInterface(interfaceId);
    }
}
