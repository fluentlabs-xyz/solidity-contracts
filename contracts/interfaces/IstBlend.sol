// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title IstBlendErrors
 * @author Fluent Labs
 * @notice Error set for {stBlend}.
 */
interface IstBlendErrors {
    /**
     * @notice Required address parameter is the zero address.
     */
    error ZeroAddressNotAllowed(string field);

    /**
     * @notice Required amount parameter is zero where a positive value is mandatory
     *         (e.g. {notifyRewards}, {depositWithSig}, {mintWithSig}).
     */
    error ZeroAmount();

    /**
     * @notice An EIP-712 signature was presented past its `deadline`.
     */
    error ExpiredSignature(uint256 deadline);

    /**
     * @notice The recovered signer does not match the expected `owner`.
     */
    error InvalidSigner(address recovered, address owner);

    /**
     * @notice {setStreamDuration} was called with a value outside the safety bounds.
     * @dev `min` / `max` are inclusive.
     */
    error InvalidStreamDuration(uint64 duration, uint64 min, uint64 max);

    /**
     * @notice A reward notification would push the streaming rate to zero (i.e. the residual
     *         pool divided by the stream duration rounds down to zero per second).
     */
    error RewardRateZero();

    /**
     * @notice Deposit / mint would push {totalAssets} past the admin-configured cap.
     */
    error TvlCapExceeded(uint256 attempted, uint256 cap);
}

/**
 * @title IstBlendEvents
 * @author Fluent Labs
 * @notice Events emitted by {stBlend}.
 */
interface IstBlendEvents {
    /**
     * @notice Emitted when a fresh reward bundle has been pulled from the distributor and
     *         the streaming window has been (re)armed.
     * @param distributor Caller that contributed `amount`; must hold {REWARDS_DISTRIBUTOR_ROLE}.
     * @param amount      Newly deposited reward amount, in underlying-asset units.
     * @param rewardRate  New per-second streaming rate (rewards / streamDuration).
     * @param periodFinish Unix timestamp at which the current streaming window closes.
     */
    event RewardsNotified(address indexed distributor, uint256 amount, uint256 rewardRate, uint64 periodFinish);

    /**
     * @notice Emitted when the admin updates the rewards streaming window length.
     */
    event StreamDurationUpdated(uint64 previousDuration, uint64 newDuration);

    /**
     * @notice Emitted when the admin updates the maximum TVL cap.
     * @dev `newCap == 0` means uncapped.
     */
    event MaxTotalAssetsUpdated(uint256 previousCap, uint256 newCap);

    /**
     * @notice Emitted whenever a {depositWithSig} or {mintWithSig} consumes a nonce.
     *         Indexers can use this to track signature usage.
     */
    event StakingSignatureUsed(address indexed owner, uint256 nonce);
}

/**
 * @title IstBlend
 * @author Fluent Labs
 *
 * @notice Public surface of the {stBlend} vault: an ERC-4626 vault that issues `sTOKEN`
 *         shares against an underlying staking asset and streams external-pool rewards into
 *         the share price over a rolling window.
 *
 * @dev    Three orthogonal capability tracks:
 *
 *         1. ERC-4626 deposits / mints / withdraws / redeems. Standard semantics, with two
 *            additions:
 *              - `maxDeposit` / `maxMint` honour an admin-configurable TVL cap;
 *              - all four functions revert when the vault is paused (via {_update}).
 *
 *         2. Streaming rewards. The reward source — an external Pool contract — calls
 *            {notifyRewards} (typically once per day). Newly deposited rewards are added to
 *            the residual pool from the previous window and re-amortised over
 *            {streamDuration} seconds; the still-unstreamed portion is excluded from
 *            {totalAssets} so it cannot be front-run by a JIT depositor. After
 *            `periodFinish`, all rewards (including any rounding dust) are visible to
 *            shareholders.
 *
 *         3. EIP-712 staking permits. A signed {DepositPermit} or {MintPermit} authorises a
 *            relayer to execute a deposit/mint on the signer's behalf — useful for
 *            gas-sponsored onboarding flows. Nonces are tracked independently of the
 *            EIP-2612 {permit} nonces so users can interleave both signature types without
 *            ordering confusion.
 *
 *         Access is OpenZeppelin {AccessControlUpgradeable}:
 *           - {DEFAULT_ADMIN_ROLE}     — registry config + role grants;
 *           - {PAUSER_ROLE}            — emergency pause/unpause;
 *           - {UPGRADER_ROLE}          — authorises UUPS upgrades;
 *           - {REWARDS_DISTRIBUTOR_ROLE} — granted to the external Pool, gates {notifyRewards}.
 */
interface IstBlend is IstBlendErrors, IstBlendEvents {
    // ============ Streaming-rewards views ============

    /**
     * @notice Per-second streaming rate of the currently-active reward window, in
     *         underlying-asset units per second. Zero before the first {notifyRewards}.
     */
    function rewardRate() external view returns (uint256);

    /**
     * @notice Unix timestamp at which the active streaming window closes. Past this point
     *         {undistributedRewards} returns 0 and the residual pool is fully accrued to
     *         the share price.
     */
    function periodFinish() external view returns (uint64);

    /**
     * @notice Length of every {notifyRewards} streaming window, in seconds.
     * @dev    Set at init (typically 1 days) and updatable by {DEFAULT_ADMIN_ROLE}.
     */
    function streamDuration() external view returns (uint64);

    /**
     * @notice Portion of the current window's rewards that has not yet been released to the
     *         share price. Subtracted from the raw underlying balance inside {totalAssets}
     *         to keep JIT deposits from siphoning unvested rewards.
     */
    function undistributedRewards() external view returns (uint256);

    // ============ Cap / pause views ============

    /**
     * @notice Admin-configured maximum TVL ({totalAssets} cap). Zero means uncapped.
     */
    function maxTotalAssets() external view returns (uint256);

    // ============ EIP-712 staking-permit views ============

    /**
     * @notice EIP-712 type hash of the `DepositPermit` struct consumed by {depositWithSig}.
     * @dev    `DepositPermit(address owner,address receiver,uint256 assets,uint256 nonce,uint256 deadline)`.
     */
    // forge-lint: disable-next-line(mixed-case-function)
    function DEPOSIT_PERMIT_TYPEHASH() external pure returns (bytes32);

    /**
     * @notice EIP-712 type hash of the `MintPermit` struct consumed by {mintWithSig}.
     * @dev    `MintPermit(address owner,address receiver,uint256 shares,uint256 nonce,uint256 deadline)`.
     */
    // forge-lint: disable-next-line(mixed-case-function)
    function MINT_PERMIT_TYPEHASH() external pure returns (bytes32);

    /**
     * @notice Next available staking-permit nonce for `owner`. Distinct from the EIP-2612
     *         {nonces} counter — see {depositWithSig} for the rationale.
     */
    function stakingNonces(address owner) external view returns (uint256);

    // ============ Streaming-rewards mutators ============

    /**
     * @notice Pull `amount` underlying-asset units from the caller and amortise them — plus
     *         any unstreamed residual from the previous window — over {streamDuration}.
     *
     * @dev    Caller must hold {REWARDS_DISTRIBUTOR_ROLE} and have approved the vault for
     *         at least `amount` of the underlying. Allowed while the vault is paused so the
     *         reward machinery continues to operate even during an emergency halt.
     */
    function notifyRewards(uint256 amount) external;

    // ============ EIP-712 staking permit mutators ============

    /**
     * @notice Deposit `assets` underlying on behalf of `owner`, minting shares to `receiver`,
     *         using an EIP-712 signature in lieu of a direct {deposit} call from `owner`.
     *
     * @dev    Reverts on expired deadline, mismatched signer, or replayed nonce. The vault
     *         pulls `assets` from `owner` via the existing ERC-20 allowance pathway — pair
     *         this with an EIP-2612 {permit} on the underlying for a fully-gasless onboarding
     *         experience.
     */
    function depositWithSig(
        uint256 assets,
        address receiver,
        address owner,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 shares);

    /**
     * @notice Mint exactly `shares` shares to `receiver` on behalf of `owner`, using an
     *         EIP-712 signature in lieu of a direct {mint} call. See {depositWithSig} for
     *         the dual-permit pattern.
     */
    function mintWithSig(
        uint256 shares,
        address receiver,
        address owner,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 assets);

    // ============ Admin mutators ============

    /**
     * @notice Update the streaming window length. Takes effect on the *next* {notifyRewards}.
     */
    function setStreamDuration(uint64 newDuration) external;

    /**
     * @notice Update the TVL cap. `newCap == 0` disables the cap. Existing deposits are not
     *         affected, but new deposits/mints that would push {totalAssets} past `newCap`
     *         will revert.
     */
    function setMaxTotalAssets(uint256 newCap) external;

    /**
     * @notice Pause deposit / mint / withdraw / redeem and share transfers.
     * @dev    Restricted to {PAUSER_ROLE}; reward notifications and admin setters keep working.
     */
    function pause() external;

    /// @notice Resume normal operation.
    function unpause() external;
}
