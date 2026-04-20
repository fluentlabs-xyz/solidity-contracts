// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title IFastWithdrawalListErrors
 * @author Fluent Labs
 * @notice Error set for {FastWithdrawalList}.
 */
interface IFastWithdrawalListErrors {
    /**
     * @notice The token (or its alias bucket) is not on the fast-withdrawal allowlist.
     * @dev Returned by view methods that look up an unregistered key, and by
     *      {IFastWithdrawalList.consumeUsage} when called for a token whose resolved bucket
     *      key has not been admin-registered. See also {IGatewayBaseErrors.FastWithdrawalNotAllowed}
     *      for the gateway-level wrapping of this condition.
     */
    error TokenNotRegistered(address token);

    /**
     * @notice {IFastWithdrawalList.registerToken} was called for a token that already exists in
     *         the allowlist. Use {IFastWithdrawalList.setLimit} instead to update an existing entry.
     */
    error TokenAlreadyRegistered(address token);

    /**
     * @notice The requested `amount` would push the hourly bucket over its configured cap.
     */
    error HourlyLimitExceeded(address token, uint256 amount, uint256 hourlyUsed, uint256 hourlyLimit);

    /**
     * @notice The requested `amount` would push the daily bucket over its configured cap.
     */
    error DailyLimitExceeded(address token, uint256 amount, uint256 dailyUsed, uint256 dailyLimit);

    /**
     * @notice The requested amount or the resulting cumulative usage would not fit in the
     *         packed `uint96` usage counter. Limits are bounded at register/setLimit time, but
     *         this guard keeps the runtime cast safe.
     */
    error UsageOverflow(address token, uint256 amount);

    /**
     * @notice {IFastWithdrawalList.setAlias} was called pointing at a non-registered canonical
     *         bucket, OR pointing the alias at itself (which would be a no-op cycle).
     */
    error InvalidAliasTarget(address token, address aliasOf);

    /**
     * @notice Required address parameter (token, alias target, owner, consumer) is the zero address.
     */
    error ZeroAddressNotAllowed(string field);
}

/**
 * @title IFastWithdrawalListEvents
 * @author Fluent Labs
 * @notice Events emitted by {FastWithdrawalList}.
 */
interface IFastWithdrawalListEvents {
    /**
     * @notice Emitted when a token is added to the allowlist with its rate caps.
     */
    event TokenRegistered(address indexed token, uint256 hourlyLimit, uint256 dailyLimit);

    /**
     * @notice Emitted when a token is removed from the allowlist. The corresponding usage
     *         counters and any alias entry pointing at this bucket are wiped at the same time.
     */
    event TokenDeregistered(address indexed token);

    /**
     * @notice Emitted when an existing token's hourly/daily caps are updated. Existing usage
     *         within the current windows is preserved.
     */
    event LimitUpdated(address indexed token, uint256 hourlyLimit, uint256 dailyLimit);

    /**
     * @notice Emitted when an alias is established or cleared. `aliasOf == address(0)` indicates
     *         clearance — `token` once again refers to its own bucket.
     */
    event AliasSet(address indexed token, address indexed previousAlias, address indexed aliasOf);

    /**
     * @notice Emitted on every successful {consumeUsage} call. `bucketKey` is the post-alias
     *         resolution key whose counters were debited (so off-chain dashboards can attribute
     *         usage to the canonical bucket regardless of which physical token triggered it).
     */
    event UsageConsumed(
        address indexed consumer,
        address indexed token,
        address indexed bucketKey,
        uint256 amount,
        uint256 hourlyUsed,
        uint256 dailyUsed
    );
}

/**
 * @title IFastWithdrawalList
 * @author Fluent Labs
 *
 * @notice Per-token rate-limit registry consulted by gateways when the originating L1 batch is
 *         {BatchStatus.Preconfirmed}. Acts as the canonical "is this token allowed to be
 *         fast-withdrawn, and at what rate" oracle for the entire bridge stack.
 *
 * @dev Three responsibilities, kept narrow:
 *      1. Allowlist membership — tokens on this list are eligible for optimistic
 *         (Preconfirmed-batch) withdrawals; tokens off it are not.
 *      2. Per-token / per-bucket hourly + daily caps — the rate limit applied to optimistic
 *         withdrawals while the originating batch has not yet finalized.
 *      3. Optional aliases — multiple physical token addresses can share a single canonical
 *         bucket. The motivating use case is ETH and WETH sharing one combined limit so
 *         attackers can't drain twice the cap by parallel exploitation across the
 *         {NativeGateway} and {ERC20Gateway}.
 *
 *      Access is OpenZeppelin {AccessControl} (matching {FluentBridgeStorageLayout}):
 *        - {DEFAULT_ADMIN_ROLE} manages registry config and grants/revokes other roles.
 *        - {CONSUMER_ROLE} (declared on the implementation) gates {consumeUsage}; admin grants
 *          it to gateway addresses via the standard {grantRole} / {revokeRole} API. Without
 *          this guard any caller could grief legitimate withdrawals by pre-burning the
 *          daily cap.
 *
 *      Admin should be a timelocked multisig in production.
 */
interface IFastWithdrawalList is IFastWithdrawalListErrors, IFastWithdrawalListEvents {
    // ============ Views ============

    /**
     * @notice Returns whether `token` (after alias resolution) is on the fast-withdrawal allowlist.
     */
    function isRegistered(address token) external view returns (bool);

    /**
     * @notice Returns the hourly and daily caps for `token`'s resolved bucket.
     * @dev Reverts with {TokenNotRegistered} if the resolved bucket is not registered.
     */
    function getLimit(address token) external view returns (uint256 hourlyLimit, uint256 dailyLimit);

    /**
     * @notice Returns the current usage windows and used amounts for `token`'s resolved bucket.
     * @return currentHourWindow `block.timestamp / 1 hours`.
     * @return hourlyUsed Bucket usage in the current hour window (zero if the bucket's last
     *         recorded window is stale).
     * @return currentDayWindow `block.timestamp / 1 days`.
     * @return dailyUsed Bucket usage in the current day window (zero if stale).
     */
    function getUsage(
        address token
    ) external view returns (uint256 currentHourWindow, uint256 hourlyUsed, uint256 currentDayWindow, uint256 dailyUsed);

    /**
     * @notice Returns the canonical bucket key for `token`. If no alias is set, returns `token`.
     */
    function getAlias(address token) external view returns (address aliasOf);

    // ============ Admin (DEFAULT_ADMIN_ROLE) ============

    /**
     * @notice Adds a new token to the allowlist with hourly and daily caps. Reverts if the
     *         token is already registered — use {setLimit} to update an existing entry.
     * @dev `hourlyLimit == 0` disables the hourly cap (only the daily cap applies);
     *      symmetric for `dailyLimit == 0`. Setting both to zero is allowed and means
     *      "registered but no rate limit" (i.e. unrestricted optimistic withdrawals — admin's
     *      decision to make).
     */
    function registerToken(address token, uint256 hourlyLimit, uint256 dailyLimit) external;

    /**
     * @notice Removes a token from the allowlist. Wipes its limit config, usage counters, and
     *         clears any alias pointing into this bucket.
     */
    function unregisterToken(address token) external;

    /**
     * @notice Updates the caps for an already-registered token. Existing usage in the current
     *         windows is preserved.
     */
    function setLimit(address token, uint256 hourlyLimit, uint256 dailyLimit) external;

    /**
     * @notice Aliases `token` to `aliasOf`'s bucket so `consumeUsage(token, ...)` debits the
     *         `aliasOf` bucket. Pass `aliasOf == address(0)` to clear an existing alias.
     * @dev Used to share a single rate cap across multiple physical tokens (e.g. ETH + WETH).
     *      The alias target MUST be a registered token; the source `token` need not be
     *      independently registered.
     */
    function setAlias(address token, address aliasOf) external;

    // ============ Consumer (CONSUMER_ROLE) ============

    /**
     * @notice Charges `amount` against `token`'s resolved bucket. Reverts if the bucket isn't
     *         registered, the caller doesn't hold {CONSUMER_ROLE}, or the resulting hourly /
     *         daily usage would exceed its cap.
     * @dev Window semantics: at the start of each new hour/day window the corresponding used
     *      counter resets to zero before the new amount is added. Caps of zero disable that
     *      window's check.
     */
    function consumeUsage(address token, uint256 amount) external;
}
