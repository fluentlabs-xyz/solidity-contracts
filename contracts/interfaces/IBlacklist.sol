// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title IBlacklist
 * @author Fluent Labs
 * @notice Registry consulted by gateway contracts to block outbound bridge traffic
 *         from sanctioned or abusive accounts on a given chain.
 * @dev Keys are stored canonically as `bytes32` so the same registry can express both
 *      EVM addresses and cross-VM identifiers (e.g. Hyperlane-format `bytes32` recipients
 *      that may point at non-EVM destinations such as Solana ed25519 keys).
 *
 *      EVM addresses are mapped to `bytes32` via the Hyperlane left-pad convention
 *      `bytes32(uint256(uint160(addr)))`. The address-overloads of {isBlacklisted}
 *      address the same storage slot as their bytes32 equivalents, so callers may use
 *      whichever form is natural without divergence.
 */
interface IBlacklist {
    /**
     * @notice Thrown when the owner is zero.
     * @dev selector: 0x9905827b
     */
    error ZeroOwner();

    /**
     * @notice Emitted when the blacklist status of an account is updated.
     * @param account Canonical bytes32 key (Hyperlane left-padded form for EVM addresses).
     */
    event BlacklistStatusUpdated(bytes32 indexed account, bool blacklisted);

    /** @notice Returns whether `account` (canonical bytes32 form) is blacklisted. */
    function isBlacklisted(bytes32 account) external view returns (bool);

    /** @notice Convenience overload for EVM-native callers; equivalent to
     *         `isBlacklisted(bytes32(uint256(uint160(account))))`.
     */
    function isBlacklisted(address account) external view returns (bool);
}
