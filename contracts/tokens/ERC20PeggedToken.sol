// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title ERC20PeggedToken
 * @author Fluent Labs
 * @dev Pegged ERC20 representation deployed behind a UpgradeableBeacon proxy.
 *      Mint and burn are restricted to the owner (gateway). Ownership transfers use two-step
 *      handoff ({Ownable2StepUpgradeable}) so a mistaken `transferOwnership` cannot lock the token.
 *      Supports pause via {PausableUpgradeable}.
 *      Metadata (name, symbol, decimals) is set once during {initialize} and stored in an
 *      ERC-7201 namespace, allowing custom values per pegged token while remaining
 *      upgrade-safe across beacon implementations.
 */
contract ERC20PeggedToken is Initializable, ERC20Upgradeable, Ownable2StepUpgradeable, PausableUpgradeable, ERC165Upgradeable {
    /// @notice Token transfer attempted while paused.
    error TokenPaused();

    // ============ Storage ============

    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.ERC20PeggedTokenStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC20_PEGGED_TOKEN_STORAGE_LOCATION = 0xea5c5135154355712e03dcde35e2b793fa78480f142b96c715f04473f0052300;

    /// @custom:storage-location erc7201:fluent.storage.ERC20PeggedTokenStorage
    struct ERC20PeggedTokenStorage {
        /// @dev Locally stored symbol (overrides ERC20Upgradeable).
        string _symbol;
        /// @dev Locally stored name (overrides ERC20Upgradeable).
        string _name;
        /// @dev Token decimals (overrides ERC20 default of 18).
        uint8 _decimals;
        /// @dev Address of the original token on the source chain.
        address _originAddress;
        /// @dev Reserved for future storage fields.
        uint256[50] __gap;
    }

    /// @dev Returns the ERC-7201 storage pointer for ERC20PeggedToken state.
    function _getERC20PeggedTokenStorage() private pure returns (ERC20PeggedTokenStorage storage $) {
        assembly ("memory-safe") {
            $.slot := ERC20_PEGGED_TOKEN_STORAGE_LOCATION
        }
    }

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Prevent the implementation contract from being initialized directly
        _disableInitializers();
    }

    // ============ Initializer ============

    /** @notice Initializes the pegged token with metadata. The caller (`msg.sender`) becomes the owner. */
    function initialize(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address originAddress
    ) public initializer {
        // Pass empty strings because name/symbol are stored locally below,
        // overriding the default ERC20 storage to support custom per-token metadata
        __ERC20_init("", "");
        // The caller (gateway) becomes the owner — authorized to mint/burn/pause
        __Ownable_init(msg.sender);
        __Ownable2Step_init();
        __Pausable_init();
        __ERC165_init();

        ERC20PeggedTokenStorage storage $ = _getERC20PeggedTokenStorage();
        // Store metadata locally so each pegged token can have distinct values
        // even though they share the same implementation via the beacon proxy
        $._symbol = symbol_;
        $._name = name_;
        // Track the L1 origin address so the bridge can map back during withdrawals
        $._originAddress = originAddress;
        // Decimals may differ from the default 18 to match the origin token's precision
        $._decimals = decimals_;
    }

    // ============ Mint / Burn ============

    /**
     * @notice Mint tokens; restricted to owner (bridge / gateway).
     */
    function mint(address account, uint256 amount) external onlyOwner {
        // Only the gateway can mint — called when L1 tokens are deposited into the bridge
        _mint(account, amount);
    }

    /**
     * @notice Burn tokens; restricted to owner (bridge / gateway).
     */
    function burn(address account, uint256 amount) external onlyOwner {
        // Only the gateway can burn — called when L2 tokens are withdrawn back to L1
        _burn(account, amount);
    }

    // ============ Pause ============

    /**
     * @notice Pause all token transfers, mints, and burns.
     */
    function pause() external onlyOwner {
        // Emergency circuit breaker — halts all transfers, mints, and burns via _update hook
        _pause();
    }

    /**
     * @notice Unpause token transfers, mints, and burns.
     */
    function unpause() external onlyOwner {
        // Resumes normal operations after an emergency pause
        _unpause();
    }

    /// @inheritdoc ERC20Upgradeable
    function name() public view override returns (string memory) {
        // Return the locally stored name instead of the empty ERC20 default
        return _getERC20PeggedTokenStorage()._name;
    }

    /// @inheritdoc ERC20Upgradeable
    function symbol() public view override returns (string memory) {
        // Return the locally stored symbol instead of the empty ERC20 default
        return _getERC20PeggedTokenStorage()._symbol;
    }

    /// @inheritdoc ERC20Upgradeable
    function decimals() public view override returns (uint8) {
        // Return the locally stored decimals to match the origin token's precision
        return _getERC20PeggedTokenStorage()._decimals;
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
