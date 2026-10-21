// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {IGatewayBase} from "./IGatewayBase.sol";

/**
 * @title IStakingGatewayErrors
 * @author Fluent Labs
 * @notice Custom errors for {StakingGateway}.
 */
interface IStakingGatewayErrors {
    /**
     * @notice Function was called on the wrong side of the staking bridge.
     * @param expectedL2Canonical True when the function is L2-only, false when it is L1-only.
     */
    error InvalidGatewayMode(bool expectedL2Canonical);

    /**
     * @notice Address parameter must be zero for this gateway mode.
     */
    error NonZeroAddressNotAllowed(string field);
}

/**
 * @title IStakingGatewayEvents
 * @author Fluent Labs
 * @notice Events emitted by {StakingGateway}.
 */
interface IStakingGatewayEvents {
    /**
     * @notice L1 user escrowed underlying and requested L2 vault shares.
     */
    event DepositAndStakeInitiated(address indexed from, address indexed l2Receiver, uint256 assets);

    /**
     * @notice L2 gateway deposited inventory into the canonical vault and delivered shares.
     */
    event DepositAndStakeReceived(address indexed from, address indexed l2Receiver, uint256 assets, uint256 shares);

    /**
     * @notice L2 user redeemed canonical vault shares and requested L1 underlying.
     */
    event RedeemToL1Initiated(address indexed from, address indexed l1Receiver, uint256 shares, uint256 assets);

    /**
     * @notice L1 gateway released escrowed underlying to a withdrawal recipient.
     */
    event UnderlyingWithdrawalReceived(address indexed from, address indexed l1Receiver, uint256 assets);

    /**
     * @notice L2 user locked canonical vault shares and requested L1 mirror shares.
     */
    event SharesToL1Initiated(address indexed from, address indexed l1Receiver, uint256 shares);

    /**
     * @notice L1 gateway minted mirror shares to a recipient.
     */
    event SharesToL1Received(address indexed from, address indexed l1Receiver, uint256 shares);

    /**
     * @notice L1 user burned mirror shares and requested canonical L2 shares.
     */
    event SharesToL2Initiated(address indexed from, address indexed l2Receiver, uint256 shares);

    /**
     * @notice L2 gateway released locked canonical vault shares to a recipient.
     */
    event SharesToL2Received(address indexed from, address indexed l2Receiver, uint256 shares);

    /**
     * @notice Gateway staking config changed.
     */
    event StakingConfigUpdated(
        address indexed previousUnderlying,
        address indexed newUnderlying,
        address indexed previousVault,
        address newVault,
        address previousMirrorToken,
        address newMirrorToken,
        bool isL2Canonical
    );
}

/**
 * @title IStakingGateway
 * @author Fluent Labs
 *
 * @notice Native FluentBridge staking gateway for an L1-source / L2-canonical vault setup.
 *         The L1 gateway escrows underlying and mints/burns a dedicated mirror sTOKEN. The
 *         L2 gateway owns the canonical ERC-4626 vault interactions and locks/releases
 *         canonical vault shares for native share bridging.
 */
interface IStakingGateway is IGatewayBase, IStakingGatewayErrors, IStakingGatewayEvents {
    // ============ Views ============

    function getUnderlying() external view returns (address);

    function getVault() external view returns (address);

    function getMirrorToken() external view returns (address);

    function isL2Canonical() external view returns (bool);

    // ============ Admin ============

    function setStakingConfig(address underlying, address vault, address mirrorToken, bool isL2Canonical_) external;

    function acceptMirrorTokenOwnership() external;

    // ============ L1 -> L2 stake ============

    function depositAndStake(uint256 assets, address l2Receiver) external payable;

    function receiveDepositAndStake(address from, address l2Receiver, uint256 assets) external;

    // ============ L2 -> L1 redeem ============

    function redeemToL1(uint256 shares, address l1Receiver) external payable returns (uint256 assets);

    function receiveUnderlyingWithdrawal(address from, address l1Receiver, uint256 assets) external;

    // ============ Native share bridge ============

    function sendSharesToL1(uint256 shares, address l1Receiver) external payable;

    function receiveSharesToL1(address from, address l1Receiver, uint256 shares) external;

    function sendSharesToL2(uint256 shares, address l2Receiver) external payable;

    function receiveSharesToL2(address from, address l2Receiver, uint256 shares) external;
}
