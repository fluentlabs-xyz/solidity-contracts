// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IFastWithdrawalList} from "../interfaces/IFastWithdrawalList.sol";

/**
 * @title FastWithdrawalList
 * @author Fluent Labs
 *
 * @notice Per-token rate-limit registry consulted by gateways during optimistic withdrawals
 *         (originating L1 batch is {BatchStatus.Preconfirmed}). See {IFastWithdrawalList} for
 *         the design overview.
 *
 * @dev UUPS-upgradeable; storage is ERC-7201 namespaced. Access is OpenZeppelin
 *      {AccessControlUpgradeable} (matches {FluentBridgeStorageLayout}):
 *        - {DEFAULT_ADMIN_ROLE} manages registry config + role grants and authorizes upgrades.
 *          In production the holder should be a timelocked multisig.
 *        - {CONSUMER_ROLE} gates {consumeUsage}; granted to gateway addresses by the admin
 *          via the standard {AccessControlUpgradeable.grantRole} API. No bespoke setter —
 *          off-chain ops tooling should use the same role-management flow as the rest of the
 *          stack.
 *      Single instance per chain — wired into both {ERC20Gateway} and {NativeGateway} so a
 *      single combined rate cap (e.g. ETH + WETH via {setAlias}) cannot be drained twice
 *      across parallel gateways.
 */
contract FastWithdrawalList is Initializable, UUPSUpgradeable, AccessControlUpgradeable, IFastWithdrawalList {
    // ============ Constants ============

    /// @dev Maximum amount that fits in the packed `uint96` usage counters.
    uint256 internal constant MAX_PACKED_USAGE = type(uint96).max;

    /// @notice Role granted to gateway addresses authorised to call {consumeUsage}. Managed
    ///         by {DEFAULT_ADMIN_ROLE} via the inherited {grantRole} / {revokeRole} API.
    bytes32 public constant CONSUMER_ROLE = keccak256("CONSUMER_ROLE");

    /// @dev keccak256(abi.encode(uint256(keccak256("fluent.storage.FastWithdrawalListStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FAST_WITHDRAWAL_LIST_STORAGE_LOCATION = 0x804f4d4b120b36ce41a8d129d98351a38a3dbf44fcb6b5c99e9a5c63d1ce5d00;

    /// @custom:storage-location erc7201:fluent.storage.FastWithdrawalListStorage
    struct FastWithdrawalListStorage {
        /// @dev Allowlist + per-bucket rate caps, keyed by canonical bucket address.
        mapping(address => LimitConfig) _limits;
        /// @dev Per-bucket usage counters in the current hour/day windows.
        mapping(address => UsageInfo) _usage;
        /// @dev Optional physical-token → canonical-bucket aliases. Default (zero) means
        ///      the token is its own bucket.
        mapping(address => address) _aliases;
        /// @dev Reserved for future storage fields. Consumer permissions live in
        ///      {AccessControlUpgradeable}'s namespaced storage and so do not occupy a
        ///      slot here.
        uint256[50] __gap;
    }

    /// @dev Per-bucket rate caps. `hourlyLimit == 0` disables the hourly check; same for daily.
    struct LimitConfig {
        bool registered;
        uint96 hourlyLimit;
        uint96 dailyLimit;
    }

    /// @dev Per-bucket rolling-window usage. Window IDs are `block.timestamp / 1 hours` and
    ///      `block.timestamp / 1 days`; reads return zero when the stored window is stale.
    struct UsageInfo {
        uint32 hourlyWindow;
        uint32 dailyWindow;
        uint96 hourlyUsed;
        uint96 dailyUsed;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the upgradeable proxy. Grants {DEFAULT_ADMIN_ROLE} to `initialAdmin`,
     *         which thereafter manages registry config and {CONSUMER_ROLE} grants.
     */
    function initialize(address initialAdmin) external initializer {
        require(initialAdmin != address(0), ZeroAddressNotAllowed("initialAdmin"));
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
    }

    // ============ Views ============

    /// @inheritdoc IFastWithdrawalList
    function isRegistered(address token) external view returns (bool) {
        return _getStorage()._limits[_resolveKey(token)].registered;
    }

    /// @inheritdoc IFastWithdrawalList
    function getLimit(address token) external view returns (uint256 hourlyLimit, uint256 dailyLimit) {
        address key = _resolveKey(token);
        LimitConfig storage config = _getStorage()._limits[key];
        require(config.registered, TokenNotRegistered(key));
        return (uint256(config.hourlyLimit), uint256(config.dailyLimit));
    }

    /// @inheritdoc IFastWithdrawalList
    function getUsage(
        address token
    ) external view returns (uint256 currentHourWindow, uint256 hourlyUsed, uint256 currentDayWindow, uint256 dailyUsed) {
        address key = _resolveKey(token);
        UsageInfo storage usage = _getStorage()._usage[key];
        currentHourWindow = block.timestamp / 1 hours;
        currentDayWindow = block.timestamp / 1 days;
        // Return zero when the stored window is stale, mirroring the consume-side semantics
        // so off-chain dashboards see the same fresh-window counters the contract uses.
        hourlyUsed = uint256(usage.hourlyWindow) == currentHourWindow ? uint256(usage.hourlyUsed) : 0;
        dailyUsed = uint256(usage.dailyWindow) == currentDayWindow ? uint256(usage.dailyUsed) : 0;
    }

    /// @inheritdoc IFastWithdrawalList
    function getAlias(address token) external view returns (address aliasOf) {
        return _getStorage()._aliases[token];
    }

    // ============ Admin (DEFAULT_ADMIN_ROLE) ============

    /// @inheritdoc IFastWithdrawalList
    function registerToken(address token, uint256 hourlyLimit, uint256 dailyLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0), ZeroAddressNotAllowed("token"));
        require(hourlyLimit <= MAX_PACKED_USAGE, UsageOverflow(token, hourlyLimit));
        require(dailyLimit <= MAX_PACKED_USAGE, UsageOverflow(token, dailyLimit));

        FastWithdrawalListStorage storage $ = _getStorage();
        LimitConfig storage config = $._limits[token];
        require(!config.registered, TokenAlreadyRegistered(token));

        config.registered = true;
        // SAFE: bounded above by MAX_PACKED_USAGE checks immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        config.hourlyLimit = uint96(hourlyLimit);
        // forge-lint: disable-next-line(unsafe-typecast)
        config.dailyLimit = uint96(dailyLimit);

        emit TokenRegistered(token, hourlyLimit, dailyLimit);
    }

    /// @inheritdoc IFastWithdrawalList
    function deregisterToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        FastWithdrawalListStorage storage $ = _getStorage();
        require($._limits[token].registered, TokenNotRegistered(token));

        // Wipe limit config + usage counters together so a future re-registration starts clean.
        // Aliases pointing at this bucket from other tokens are deliberately left in place —
        // they'll resolve to an unregistered key on the next consume and revert cleanly.
        delete $._limits[token];
        delete $._usage[token];

        emit TokenDeregistered(token);
    }

    /// @inheritdoc IFastWithdrawalList
    function setLimit(address token, uint256 hourlyLimit, uint256 dailyLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(hourlyLimit <= MAX_PACKED_USAGE, UsageOverflow(token, hourlyLimit));
        require(dailyLimit <= MAX_PACKED_USAGE, UsageOverflow(token, dailyLimit));

        FastWithdrawalListStorage storage $ = _getStorage();
        LimitConfig storage config = $._limits[token];
        require(config.registered, TokenNotRegistered(token));

        // forge-lint: disable-next-line(unsafe-typecast)
        config.hourlyLimit = uint96(hourlyLimit);
        // forge-lint: disable-next-line(unsafe-typecast)
        config.dailyLimit = uint96(dailyLimit);

        emit LimitUpdated(token, hourlyLimit, dailyLimit);
    }

    /// @inheritdoc IFastWithdrawalList
    function setAlias(address token, address aliasOf) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0), ZeroAddressNotAllowed("token"));
        FastWithdrawalListStorage storage $ = _getStorage();
        address previous = $._aliases[token];

        if (aliasOf == address(0)) {
            // Clear the alias — `token` returns to using itself as the bucket.
            delete $._aliases[token];
        } else {
            // Reject self-alias (no-op cycle) and aliases pointing at non-registered buckets.
            // The latter is caught here rather than at consume time so misconfiguration is
            // detected synchronously when the admin sets it.
            require(aliasOf != token, InvalidAliasTarget(token, aliasOf));
            require($._limits[aliasOf].registered, InvalidAliasTarget(token, aliasOf));
            $._aliases[token] = aliasOf;
        }

        emit AliasSet(token, previous, aliasOf);
    }

    // ============ Consumer (CONSUMER_ROLE) ============

    /// @inheritdoc IFastWithdrawalList
    function consumeUsage(address token, uint256 amount) external onlyRole(CONSUMER_ROLE) {
        FastWithdrawalListStorage storage $ = _getStorage();
        address key = _resolveKey(token);
        LimitConfig storage config = $._limits[key];
        require(config.registered, TokenNotRegistered(key));

        // Defensive: a user-driven `amount` larger than the packed counter would silently
        // truncate on the cast below; reject up-front instead.
        require(amount <= MAX_PACKED_USAGE, UsageOverflow(key, amount));

        UsageInfo storage usage = $._usage[key];
        // SAFE: bounded by the year 2106 for hour/day windows; well within uint32 lifetime.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 currentHourWindow = uint32(block.timestamp / 1 hours);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 currentDayWindow = uint32(block.timestamp / 1 days);

        // Window-roll: reset the bucket counter if the stored window is stale, then add `amount`.
        uint256 newHourlyUsed = (uint256(usage.hourlyWindow) == uint256(currentHourWindow)) ? uint256(usage.hourlyUsed) + amount : amount;
        uint256 newDailyUsed = (uint256(usage.dailyWindow) == uint256(currentDayWindow)) ? uint256(usage.dailyUsed) + amount : amount;

        if (config.hourlyLimit != 0) {
            require(
                newHourlyUsed <= uint256(config.hourlyLimit),
                HourlyLimitExceeded(key, amount, uint256(usage.hourlyUsed), uint256(config.hourlyLimit))
            );
        }
        if (config.dailyLimit != 0) {
            require(
                newDailyUsed <= uint256(config.dailyLimit),
                DailyLimitExceeded(key, amount, uint256(usage.dailyUsed), uint256(config.dailyLimit))
            );
        }

        // Final overflow guard before truncating into the packed `uint96` slots.
        require(newHourlyUsed <= MAX_PACKED_USAGE && newDailyUsed <= MAX_PACKED_USAGE, UsageOverflow(key, amount));

        usage.hourlyWindow = currentHourWindow;
        usage.dailyWindow = currentDayWindow;
        // forge-lint: disable-next-line(unsafe-typecast)
        usage.hourlyUsed = uint96(newHourlyUsed);
        // forge-lint: disable-next-line(unsafe-typecast)
        usage.dailyUsed = uint96(newDailyUsed);

        emit UsageConsumed(msg.sender, token, key, amount, newHourlyUsed, newDailyUsed);
    }

    // ============ Internal ============

    /// @dev Returns the canonical bucket key for `token`. Defaults to `token` itself when no
    ///      alias has been configured.
    function _resolveKey(address token) internal view returns (address) {
        address aliasOf = _getStorage()._aliases[token];
        return aliasOf == address(0) ? token : aliasOf;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /// @dev Returns the storage pointer for the FastWithdrawalListStorage struct.
    function _getStorage() private pure returns (FastWithdrawalListStorage storage $) {
        assembly ("memory-safe") {
            $.slot := FAST_WITHDRAWAL_LIST_STORAGE_LOCATION
        }
    }
}
