// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IstBlend} from "../interfaces/IstBlend.sol";

/**
 * @title stBlend
 * @author Fluent Labs
 *
 * @notice ERC-4626 tokenised vault that issues `sTOKEN` shares against a single staking asset
 *         and accrues external-pool rewards by streaming them into the share price over a
 *         rolling window (typically 1 day).
 *
 * @dev    The vault is upgradeable (UUPS), pausable, reentrancy-guarded, and uses
 *         OpenZeppelin {AccessControlUpgradeable} to gate privileged actions.
 *
 *         == Rewards model ==
 *
 *         Rewards originate from an *external* Pool contract that holds the
 *         {REWARDS_DISTRIBUTOR_ROLE}. Once per epoch (e.g. once per day) the Pool calls
 *         {notifyRewards}, depositing fresh underlying-asset units into the vault. Newly
 *         received rewards are merged with any unstreamed residual from the previous window
 *         and re-amortised over {streamDuration} seconds. The portion that has not yet been
 *         "released" (`{undistributedRewards}`) is subtracted from {totalAssets}, so the
 *         share price grows linearly inside each window rather than jumping in a single
 *         block. This blocks the classic "JIT donation" sandwich where a depositor enters
 *         immediately before a reward drop and exits immediately after.
 *
 *         After `periodFinish` the residual pool — including any rounding dust from the
 *         per-second rate truncation — is fully visible to shareholders.
 *
 *         == EIP-712 staking permits ==
 *
 *         {depositWithSig} / {mintWithSig} accept a signed `DepositPermit` / `MintPermit`
 *         message and execute the deposit/mint on behalf of the signing `owner`. This is
 *         the gas-sponsorship path used by relayer-based onboarding UIs. The staking-permit
 *         nonce counter ({stakingNonces}) is kept separate from the EIP-2612 share-permit
 *         nonces ({nonces}) so users can interleave both signature types without ordering
 *         confusion.
 *
 *         Pair {depositWithSig} with an EIP-2612 {permit} on the underlying token (in the
 *         same transaction) for a fully-gasless deposit experience.
 *
 *         == Storage ==
 *
 *         All vault-local state lives inside an ERC-7201 namespaced struct so future
 *         upgrades may append fields without colliding with inherited OZ storage modules.
 *         The five inherited upgradeables already use their own namespaced slots.
 */
contract stBlend is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ERC4626Upgradeable,
    ERC20PermitUpgradeable,
    IstBlend
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ============ Constants ============

    /// @notice Role granted to addresses authorised to pause / unpause the vault.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Role granted to addresses authorised to perform UUPS upgrades.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /**
     * @notice Role granted to the external Pool contract that funds the vault with rewards
     *         via {notifyRewards}. Should be the only address that ever holds it.
     */
    bytes32 public constant REWARDS_DISTRIBUTOR_ROLE = keccak256("REWARDS_DISTRIBUTOR_ROLE");

    /// @inheritdoc IstBlend
    // forge-lint: disable-next-line(mixed-case-function)
    bytes32 public constant DEPOSIT_PERMIT_TYPEHASH =
        keccak256("DepositPermit(address owner,address receiver,uint256 assets,uint256 nonce,uint256 deadline)");

    /// @inheritdoc IstBlend
    // forge-lint: disable-next-line(mixed-case-function)
    bytes32 public constant MINT_PERMIT_TYPEHASH =
        keccak256("MintPermit(address owner,address receiver,uint256 shares,uint256 nonce,uint256 deadline)");

    /// @dev Lower bound on {streamDuration}. Shorter windows make front-running the
    ///      reward drop trivially profitable; one hour is the smallest safe value.
    uint64 public constant MIN_STREAM_DURATION = 1 hours;

    /// @dev Upper bound on {streamDuration}. Prevents an admin from soft-bricking the
    ///      vault by setting a duration so long that practically no rewards accrue.
    uint64 public constant MAX_STREAM_DURATION = 30 days;

    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.FluentStakedVaultStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FLUENT_STAKED_VAULT_STORAGE_LOCATION = 0xed45df4df437d8b363839bb27aa9bb796eff04ce1c9daab9a7aa43a4e2fadf00;

    // ============ Storage ============

    /// @custom:storage-location erc7201:Fluent.storage.FluentStakedVaultStorage
    struct FluentStakedVaultStorage {
        /// @dev Per-second reward streaming rate of the active window, in underlying units.
        ///      Packed with `_periodFinish` into a single slot.
        uint128 _rewardRate;
        /// @dev Length of every {notifyRewards} streaming window, in seconds.
        uint64 _streamDuration;
        /// @dev Unix timestamp at which the active streaming window ends. Until then,
        ///      `rewardRate * (periodFinish - block.timestamp)` is excluded from `totalAssets`.
        uint64 _periodFinish;
        /// @dev Maximum allowed {totalAssets}. 0 means uncapped.
        uint256 _maxTotalAssets;
        /// @dev Per-account nonce counter for {depositWithSig} / {mintWithSig}. Kept separate
        ///      from the inherited EIP-2612 share-permit nonces.
        mapping(address => uint256) _stakingNonces;
        /// @dev Reserved for future storage fields.
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256[46] __gap;
    }

    function _getStorage() private pure returns (FluentStakedVaultStorage storage $) {
        assembly ("memory-safe") {
            $.slot := FLUENT_STAKED_VAULT_STORAGE_LOCATION
        }
    }

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /**
     * @notice One-shot initialiser for the upgradeable proxy.
     *
     * @param asset_              Underlying staking asset (ERC-20).
     * @param name_               ERC-20 name of the share token, e.g. `"Staked Fluent"`.
     * @param symbol_             ERC-20 symbol of the share token, e.g. `"sFLUENT"`.
     * @param admin_              Holder of {DEFAULT_ADMIN_ROLE}; also receives {UPGRADER_ROLE}.
     *                            In production this should be a timelocked multisig.
     * @param pauser_             Holder of {PAUSER_ROLE}.
     * @param rewardsDistributor_ External Pool contract granted {REWARDS_DISTRIBUTOR_ROLE}.
     * @param streamDuration_     Length of every reward streaming window, in seconds. Must
     *                            satisfy {MIN_STREAM_DURATION} ≤ value ≤ {MAX_STREAM_DURATION}.
     * @param maxTotalAssets_     Initial TVL cap, in underlying units. Zero disables the cap.
     */
    function initialize(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address admin_,
        address pauser_,
        address rewardsDistributor_,
        uint64 streamDuration_,
        uint256 maxTotalAssets_
    ) external initializer {
        require(address(asset_) != address(0), ZeroAddressNotAllowed("asset"));
        require(admin_ != address(0), ZeroAddressNotAllowed("admin"));
        require(pauser_ != address(0), ZeroAddressNotAllowed("pauser"));
        require(rewardsDistributor_ != address(0), ZeroAddressNotAllowed("rewardsDistributor"));
        require(
            streamDuration_ >= MIN_STREAM_DURATION && streamDuration_ <= MAX_STREAM_DURATION,
            InvalidStreamDuration(streamDuration_, MIN_STREAM_DURATION, MAX_STREAM_DURATION)
        );

        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __AccessControl_init();
        __ERC20_init(name_, symbol_);
        __ERC4626_init(asset_);
        // EIP-712 domain is derived from the share-token name; matches the EIP-2612 permit
        // domain so wallets can render both signature types under the same dApp identity.
        __ERC20Permit_init(name_);

        FluentStakedVaultStorage storage $ = _getStorage();
        $._streamDuration = streamDuration_;
        $._maxTotalAssets = maxTotalAssets_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(UPGRADER_ROLE, admin_);
        _grantRole(PAUSER_ROLE, pauser_);
        _grantRole(REWARDS_DISTRIBUTOR_ROLE, rewardsDistributor_);
    }

    // ============ Streaming-rewards views ============

    /// @inheritdoc IstBlend
    function rewardRate() external view returns (uint256) {
        return uint256(_getStorage()._rewardRate);
    }

    /// @inheritdoc IstBlend
    function periodFinish() external view returns (uint64) {
        return _getStorage()._periodFinish;
    }

    /// @inheritdoc IstBlend
    function streamDuration() external view returns (uint64) {
        return _getStorage()._streamDuration;
    }

    /// @inheritdoc IstBlend
    function undistributedRewards() public view returns (uint256) {
        return _undistributedRewards(_getStorage());
    }

    /**
     * @dev See {IERC4626-totalAssets}. Overrides the raw-balance default to exclude any
     *      portion of the active reward stream that has not yet been released. After
     *      `periodFinish` the exclusion is zero and the entire underlying balance — including
     *      rounding dust from the per-second rate — is visible to shareholders.
     */
    function totalAssets() public view virtual override returns (uint256) {
        FluentStakedVaultStorage storage $ = _getStorage();
        return IERC20(asset()).balanceOf(address(this)) - _undistributedRewards($);
    }

    // ============ Cap / pause views ============

    /// @inheritdoc IstBlend
    function maxTotalAssets() external view returns (uint256) {
        return _getStorage()._maxTotalAssets;
    }

    /// @dev See {IERC4626-maxDeposit}. Returns 0 while paused and clamps to the TVL cap.
    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        if (paused()) return 0;
        FluentStakedVaultStorage storage $ = _getStorage();
        uint256 cap = $._maxTotalAssets;
        if (cap == 0) return super.maxDeposit(receiver);
        uint256 ta = totalAssets();
        // Treat ta > cap (admin lowered the cap) as fully-capped rather than reverting.
        return ta >= cap ? 0 : cap - ta;
    }

    /// @dev See {IERC4626-maxMint}. Returns 0 while paused and clamps to the TVL cap.
    function maxMint(address receiver) public view virtual override returns (uint256) {
        if (paused()) return 0;
        FluentStakedVaultStorage storage $ = _getStorage();
        uint256 cap = $._maxTotalAssets;
        if (cap == 0) return super.maxMint(receiver);
        uint256 ta = totalAssets();
        if (ta >= cap) return 0;
        // Floor to avoid issuing one extra share that would push assets over the cap.
        return _convertToShares(cap - ta, Math.Rounding.Floor);
    }

    // ============ EIP-712 staking-permit views ============

    /// @inheritdoc IstBlend
    function stakingNonces(address owner) external view returns (uint256) {
        return _getStorage()._stakingNonces[owner];
    }

    // ============ ERC-4626 mutators (nonReentrant) ============

    /// @dev See {IERC4626-deposit}. Wrapped in {nonReentrant} as a defence-in-depth against
    ///      malicious or upgraded underlying tokens — the asset is trusted at init time but
    ///      the guard is cheap and removes the failure mode entirely.
    function deposit(uint256 assets, address receiver) public virtual override nonReentrant returns (uint256) {
        return super.deposit(assets, receiver);
    }

    /// @dev See {IERC4626-mint}.
    function mint(uint256 shares, address receiver) public virtual override nonReentrant returns (uint256) {
        return super.mint(shares, receiver);
    }

    /// @dev See {IERC4626-withdraw}.
    function withdraw(uint256 assets, address receiver, address owner) public virtual override nonReentrant returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    /// @dev See {IERC4626-redeem}.
    function redeem(uint256 shares, address receiver, address owner) public virtual override nonReentrant returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    // ============ Streaming-rewards mutators ============

    /// @inheritdoc IstBlend
    function notifyRewards(uint256 amount) external onlyRole(REWARDS_DISTRIBUTOR_ROLE) nonReentrant {
        require(amount != 0, ZeroAmount());

        FluentStakedVaultStorage storage $ = _getStorage();
        uint64 sd = $._streamDuration;

        // Carry the previous window's unstreamed residual into the new window so a partially
        // distributed pool is not lost when the distributor tops up early.
        uint256 leftover = _undistributedRewards($);
        uint256 newPool = leftover + amount;

        // Per-second rate. Rounding down is intentional — any dust falls through to the
        // share price once the window closes (see {totalAssets}).
        uint256 rate = newPool / uint256(sd);
        // Both bounds collapse into a single RewardRateZero error: rate == 0 trips the floor
        // guard, rate > uint128.max is unreachable from a well-bounded asset but kept as a
        // defence-in-depth cast guard.
        require(rate != 0 && rate <= type(uint128).max, RewardRateZero());

        // Pull rewards from the distributor (the external Pool). Trusted role; the
        // SafeERC20 call is also covered by the {nonReentrant} guard above.
        IERC20(asset()).safeTransferFrom(_msgSender(), address(this), amount);

        // forge-lint: disable-next-line(unsafe-typecast)
        $._rewardRate = uint128(rate);
        // SAFE: block.timestamp fits in uint64 until year 2554; sd is bounded by MAX_STREAM_DURATION.
        // forge-lint: disable-next-line(unsafe-typecast)
        $._periodFinish = uint64(block.timestamp) + sd;

        emit RewardsNotified(_msgSender(), amount, rate, $._periodFinish);
    }

    // ============ EIP-712 staking permit mutators ============

    /// @inheritdoc IstBlend
    function depositWithSig(
        uint256 assets,
        address receiver,
        address owner,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 shares) {
        require(assets != 0, ZeroAmount());
        _verifyStakingPermit(DEPOSIT_PERMIT_TYPEHASH, owner, receiver, assets, deadline, v, r, s);

        // Mirror the cap / pause semantics of {deposit} by going through the public-API
        // checks. {maxDeposit} returns 0 while paused, so paused vaults always revert here.
        uint256 maxA = maxDeposit(receiver);
        if (assets > maxA) revert ERC4626ExceededMaxDeposit(receiver, assets, maxA);

        shares = previewDeposit(assets);
        // `_deposit(caller, ...)` pulls `assets` from `caller` — pass `owner` so the
        // signer (not the relayer) funds the deposit.
        _deposit(owner, receiver, assets, shares);
    }

    /// @inheritdoc IstBlend
    function mintWithSig(
        uint256 shares,
        address receiver,
        address owner,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 assets) {
        require(shares != 0, ZeroAmount());
        _verifyStakingPermit(MINT_PERMIT_TYPEHASH, owner, receiver, shares, deadline, v, r, s);

        uint256 maxS = maxMint(receiver);
        if (shares > maxS) revert ERC4626ExceededMaxMint(receiver, shares, maxS);

        assets = previewMint(shares);
        _deposit(owner, receiver, assets, shares);
    }

    // ============ Admin mutators ============

    /// @inheritdoc IstBlend
    function setStreamDuration(uint64 newDuration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            newDuration >= MIN_STREAM_DURATION && newDuration <= MAX_STREAM_DURATION,
            InvalidStreamDuration(newDuration, MIN_STREAM_DURATION, MAX_STREAM_DURATION)
        );
        FluentStakedVaultStorage storage $ = _getStorage();
        uint64 previous = $._streamDuration;
        $._streamDuration = newDuration;
        // Does NOT retroactively reshape the active window — the next {notifyRewards} call
        // will pick up the new duration when it re-amortises the residual + fresh amount.
        emit StreamDurationUpdated(previous, newDuration);
    }

    /// @inheritdoc IstBlend
    function setMaxTotalAssets(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        FluentStakedVaultStorage storage $ = _getStorage();
        uint256 previous = $._maxTotalAssets;
        $._maxTotalAssets = newCap;
        emit MaxTotalAssetsUpdated(previous, newCap);
    }

    /// @inheritdoc IstBlend
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @inheritdoc IstBlend
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ============ Internal ============

    /**
     * @dev Shared signature-verification path for {depositWithSig} / {mintWithSig}.
     *      Reverts on expired deadline, signer mismatch, or replayed nonce. On success,
     *      consumes a staking-permit nonce and emits {StakingSignatureUsed}.
     */
    function _verifyStakingPermit(
        bytes32 typeHash,
        address owner,
        address receiver,
        uint256 valueField,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        require(owner != address(0), ZeroAddressNotAllowed("owner"));
        require(receiver != address(0), ZeroAddressNotAllowed("receiver"));
        require(block.timestamp <= deadline, ExpiredSignature(deadline));

        FluentStakedVaultStorage storage $ = _getStorage();
        uint256 nonce = $._stakingNonces[owner];

        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 structHash = keccak256(abi.encode(typeHash, owner, receiver, valueField, nonce, deadline));
        bytes32 digest = _hashTypedDataV4(structHash);

        address signer = ECDSA.recover(digest, v, r, s);
        require(signer == owner, InvalidSigner(signer, owner));

        // Effects before the deposit/mint external call so a malicious relayer cannot
        // replay the signature via reentrancy (also covered by the nonReentrant guard).
        unchecked {
            $._stakingNonces[owner] = nonce + 1;
        }
        emit StakingSignatureUsed(owner, nonce);
    }

    /// @dev Returns the still-unstreamed portion of the active reward window. Zero before
    ///      the first {notifyRewards} (periodFinish == 0 ⇒ block.timestamp >= periodFinish).
    function _undistributedRewards(FluentStakedVaultStorage storage $) internal view returns (uint256) {
        uint256 pf = uint256($._periodFinish);
        if (block.timestamp >= pf) return 0;
        // SAFE: pf > block.timestamp here, and rewardRate is bounded by uint128;
        // streamDuration is bounded by MAX_STREAM_DURATION (~30 days), so the product
        // fits comfortably in uint256.
        return uint256($._rewardRate) * (pf - block.timestamp);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // ============ Diamond resolution ============

    /**
     * @dev Enforces pause semantics on every balance mutation (mint, burn, transfer).
     *      ERC-4626 deposit/withdraw both flow through {_update}, so the single override
     *      covers staking, unstaking, and plain share transfers.
     */
    function _update(address from, address to, uint256 value) internal virtual override(ERC20Upgradeable) whenNotPaused {
        super._update(from, to, value);
    }

    /// @dev ERC-20 decimals — defer to ERC-4626's offset-aware implementation.
    function decimals() public view virtual override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8) {
        return ERC4626Upgradeable.decimals();
    }

    /// @dev EIP-2612 share-permit nonces (distinct from {stakingNonces}). Defers to
    ///      {NoncesUpgradeable} via {ERC20PermitUpgradeable}.
    function nonces(address owner) public view virtual override(ERC20PermitUpgradeable) returns (uint256) {
        return super.nonces(owner);
    }
}
