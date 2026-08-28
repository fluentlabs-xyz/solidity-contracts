// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {FluentBridge} from "../bridge/FluentBridge.sol";
import {IStakingGateway} from "../interfaces/gateways/IStakingGateway.sol";
import {GatewayBase} from "./GatewayBase.sol";
import {StakedTokenMirror} from "../tokens/StakedTokenMirror.sol";

/**
 * @title StakingGateway
 * @author Fluent Labs
 *
 * @notice Native FluentBridge gateway for L1-source / L2-canonical staking.
 *
 * @dev The gateway has two modes:
 *      - L1 mode (`isL2Canonical == false`): escrows underlying, releases underlying, and
 *        mints/burns the L1 mirror sTOKEN.
 *      - L2 mode (`isL2Canonical == true`): deposits L2 inventory into the canonical
 *        ERC-4626 vault, redeems canonical shares into inventory, and locks/releases
 *        canonical vault shares for native share movement.
 *
 *      Yield accounting lives only in the L2 vault. The L1 mirror token is a supply mirror
 *      of canonical shares locked in the L2 gateway; it never maintains ERC-4626 accounting.
 */
contract StakingGateway is GatewayBase, IStakingGateway {
    using SafeERC20 for IERC20;

    // ============ Storage ============

    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.StakingGatewayStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STAKING_GATEWAY_STORAGE_LOCATION = 0x7dc68bdfdce1044186a434c132ff988ac61ddf4b89910b3dfa6879cdc4981600;

    /// @custom:storage-location erc7201:Fluent.storage.StakingGatewayStorage
    struct StakingGatewayStorage {
        /// @dev L1 source underlying asset, and L2 inventory asset used by the canonical vault.
        address _underlying;
        /// @dev Canonical L2 ERC-4626 vault. Zero in L1 mode.
        address _vault;
        /// @dev L1 mirror sTOKEN. Zero in L2 mode.
        address _mirrorToken;
        /// @dev True for the L2 canonical vault side; false for the L1 source side.
        bool _isL2Canonical;
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256[46] __gap;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes an L1 or L2 staking gateway.
     * @param initialOwner Owner/admin of the gateway.
     * @param bridgeContract Local FluentBridge address.
     * @param underlying L1 source asset or L2 inventory asset.
     * @param vault Canonical ERC-4626 vault. Required in L2 mode, zero in L1 mode.
     * @param mirrorToken L1 mirror sTOKEN. Required in L1 mode, zero in L2 mode.
     * @param isL2Canonical_ True when deployed next to the canonical L2 vault.
     */
    function initialize(
        address initialOwner,
        address bridgeContract,
        address underlying,
        address vault,
        address mirrorToken,
        bool isL2Canonical_
    ) external initializer {
        __GatewayBase_init(initialOwner, bridgeContract);
        _setStakingConfig(underlying, vault, mirrorToken, isL2Canonical_);
    }

    // ============ Views ============

    /// @inheritdoc IStakingGateway
    function getUnderlying() public view returns (address) {
        return _getStorage()._underlying;
    }

    /// @inheritdoc IStakingGateway
    function getVault() public view returns (address) {
        return _getStorage()._vault;
    }

    /// @inheritdoc IStakingGateway
    function getMirrorToken() public view returns (address) {
        return _getStorage()._mirrorToken;
    }

    /// @inheritdoc IStakingGateway
    function isL2Canonical() public view returns (bool) {
        return _getStorage()._isL2Canonical;
    }

    // ============ Admin ============

    /**
     * @notice Updates staking-specific routing config.
     * @dev Use sparingly; the gateway mode controls which side-only functions are enabled.
     */
    /// @inheritdoc IStakingGateway
    function setStakingConfig(address underlying, address vault, address mirrorToken, bool isL2Canonical_) external onlyOwner {
        _setStakingConfig(underlying, vault, mirrorToken, isL2Canonical_);
    }

    /**
     * @notice Accepts ownership of the configured L1 mirror token after the current owner
     *         calls {StakedTokenMirror.transferOwnership} to this gateway.
     */
    /// @inheritdoc IStakingGateway
    function acceptMirrorTokenOwnership() external onlyOwner {
        _requireMode(false);
        StakedTokenMirror(getMirrorToken()).acceptOwnership();
    }

    // ============ L1 -> L2 stake ============

    /// @inheritdoc IStakingGateway
    function depositAndStake(uint256 assets, address l2Receiver) external payable nonReentrant {
        _requireMode(false);
        require(assets > 0, ZeroValueNotAllowed("assets"));
        require(l2Receiver != address(0), InvalidRecipient());
        require(msg.value == FluentBridge(getBridgeContract()).getSentMessageFee(), ExactFeeRequired());

        address sender = msg.sender;
        _requireAccountNotBlacklisted(sender);
        _requireAccountNotBlacklisted(l2Receiver);

        IERC20(getUnderlying()).safeTransferFrom(sender, address(this), assets);

        FluentBridge(getBridgeContract()).sendMessage{value: msg.value}(
            getOtherSideGateway(),
            abi.encodeCall(IStakingGateway.receiveDepositAndStake, (sender, l2Receiver, assets))
        );

        emit DepositAndStakeInitiated(sender, l2Receiver, assets);
    }

    /// @inheritdoc IStakingGateway
    function receiveDepositAndStake(address from, address l2Receiver, uint256 assets) external onlyFluentBridge nonReentrant {
        _requireMode(true);
        _requireRemoteGateway();
        require(assets > 0, ZeroValueNotAllowed("assets"));
        require(l2Receiver != address(0), InvalidRecipient());
        _requireAccountNotBlacklisted(from);
        _requireAccountNotBlacklisted(l2Receiver);

        address vault = getVault();
        uint256 shares = IERC4626(vault).deposit(assets, l2Receiver);

        emit DepositAndStakeReceived(from, l2Receiver, assets, shares);
    }

    // ============ L2 -> L1 redeem ============

    /// @inheritdoc IStakingGateway
    function redeemToL1(uint256 shares, address l1Receiver) external payable nonReentrant returns (uint256 assets) {
        _requireMode(true);
        require(shares > 0, ZeroValueNotAllowed("shares"));
        require(l1Receiver != address(0), InvalidRecipient());
        require(msg.value == FluentBridge(getBridgeContract()).getSentMessageFee(), ExactFeeRequired());

        address sender = msg.sender;
        _requireAccountNotBlacklisted(sender);
        _requireAccountNotBlacklisted(l1Receiver);

        address vault = getVault();
        IERC20(vault).safeTransferFrom(sender, address(this), shares);
        assets = IERC4626(vault).redeem(shares, address(this), address(this));

        FluentBridge(getBridgeContract()).sendMessage{value: msg.value}(
            getOtherSideGateway(),
            abi.encodeCall(IStakingGateway.receiveUnderlyingWithdrawal, (sender, l1Receiver, assets))
        );

        emit RedeemToL1Initiated(sender, l1Receiver, shares, assets);
    }

    /// @inheritdoc IStakingGateway
    function receiveUnderlyingWithdrawal(address from, address l1Receiver, uint256 assets) external onlyFluentBridge nonReentrant {
        _requireMode(false);
        _requireRemoteGateway();
        require(assets > 0, ZeroValueNotAllowed("assets"));
        require(l1Receiver != address(0), InvalidRecipient());
        _requireAccountNotBlacklisted(from);
        _requireAccountNotBlacklisted(l1Receiver);

        address underlying = getUnderlying();
        _consumeLimit(underlying, assets);
        IERC20(underlying).safeTransfer(l1Receiver, assets);

        emit UnderlyingWithdrawalReceived(from, l1Receiver, assets);
    }

    // ============ Native share bridge ============

    /// @inheritdoc IStakingGateway
    function sendSharesToL1(uint256 shares, address l1Receiver) external payable nonReentrant {
        _requireMode(true);
        require(shares > 0, ZeroValueNotAllowed("shares"));
        require(l1Receiver != address(0), InvalidRecipient());
        require(msg.value == FluentBridge(getBridgeContract()).getSentMessageFee(), ExactFeeRequired());

        address sender = msg.sender;
        _requireAccountNotBlacklisted(sender);
        _requireAccountNotBlacklisted(l1Receiver);

        IERC20(getVault()).safeTransferFrom(sender, address(this), shares);

        FluentBridge(getBridgeContract()).sendMessage{value: msg.value}(
            getOtherSideGateway(),
            abi.encodeCall(IStakingGateway.receiveSharesToL1, (sender, l1Receiver, shares))
        );

        emit SharesToL1Initiated(sender, l1Receiver, shares);
    }

    /// @inheritdoc IStakingGateway
    function receiveSharesToL1(address from, address l1Receiver, uint256 shares) external onlyFluentBridge nonReentrant {
        _requireMode(false);
        _requireRemoteGateway();
        require(shares > 0, ZeroValueNotAllowed("shares"));
        require(l1Receiver != address(0), InvalidRecipient());
        _requireAccountNotBlacklisted(from);
        _requireAccountNotBlacklisted(l1Receiver);

        address mirrorToken = getMirrorToken();
        _consumeLimit(mirrorToken, shares);
        StakedTokenMirror(mirrorToken).mint(l1Receiver, shares);

        emit SharesToL1Received(from, l1Receiver, shares);
    }

    /// @inheritdoc IStakingGateway
    function sendSharesToL2(uint256 shares, address l2Receiver) external payable nonReentrant {
        _requireMode(false);
        require(shares > 0, ZeroValueNotAllowed("shares"));
        require(l2Receiver != address(0), InvalidRecipient());
        require(msg.value == FluentBridge(getBridgeContract()).getSentMessageFee(), ExactFeeRequired());

        address sender = msg.sender;
        _requireAccountNotBlacklisted(sender);
        _requireAccountNotBlacklisted(l2Receiver);

        StakedTokenMirror(getMirrorToken()).burn(sender, shares);

        FluentBridge(getBridgeContract()).sendMessage{value: msg.value}(
            getOtherSideGateway(),
            abi.encodeCall(IStakingGateway.receiveSharesToL2, (sender, l2Receiver, shares))
        );

        emit SharesToL2Initiated(sender, l2Receiver, shares);
    }

    /// @inheritdoc IStakingGateway
    function receiveSharesToL2(address from, address l2Receiver, uint256 shares) external onlyFluentBridge nonReentrant {
        _requireMode(true);
        _requireRemoteGateway();
        require(shares > 0, ZeroValueNotAllowed("shares"));
        require(l2Receiver != address(0), InvalidRecipient());
        _requireAccountNotBlacklisted(from);
        _requireAccountNotBlacklisted(l2Receiver);

        IERC20(getVault()).safeTransfer(l2Receiver, shares);

        emit SharesToL2Received(from, l2Receiver, shares);
    }

    // ============ Internal ============

    function _setStakingConfig(address underlying, address vault, address mirrorToken, bool isL2Canonical_) internal {
        require(underlying != address(0), ZeroAddressNotAllowed("underlying"));
        if (isL2Canonical_) {
            require(vault != address(0), ZeroAddressNotAllowed("vault"));
            require(mirrorToken == address(0), NonZeroAddressNotAllowed("mirrorToken"));
        } else {
            require(vault == address(0), NonZeroAddressNotAllowed("vault"));
            require(mirrorToken != address(0), ZeroAddressNotAllowed("mirrorToken"));
        }

        StakingGatewayStorage storage $ = _getStorage();
        emit StakingConfigUpdated($._underlying, underlying, $._vault, vault, $._mirrorToken, mirrorToken, isL2Canonical_);
        $._underlying = underlying;
        $._vault = vault;
        $._mirrorToken = mirrorToken;
        $._isL2Canonical = isL2Canonical_;

        if (isL2Canonical_) {
            IERC20(underlying).forceApprove(vault, type(uint256).max);
        }
    }

    function _requireMode(bool expectedL2Canonical) internal view {
        require(_getStorage()._isL2Canonical == expectedL2Canonical, InvalidGatewayMode(expectedL2Canonical));
    }

    function _requireRemoteGateway() internal view {
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
    }

    function _getStorage() private pure returns (StakingGatewayStorage storage $) {
        assembly ("memory-safe") {
            $.slot := STAKING_GATEWAY_STORAGE_LOCATION
        }
    }
}
