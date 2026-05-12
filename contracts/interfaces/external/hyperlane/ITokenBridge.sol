// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title ITokenBridge
 * @notice Hyperlane v10 warp route interface used by Fluent's L1 Hyperlane gateway.
 *
 * @dev Source of truth: https://docs.hyperlane.xyz/docs/applications/warp-routes/interface.
 *      Only the surface actually consumed by the gateway is declared here. The full
 *      Hyperlane implementation lives in the hyperlane-xyz/core package and is not
 *      depended on at compile time.
 *
 * @dev Semantics:
 *      - `_amount` is exact-out: the destination recipient receives exactly `_amount`.
 *        Fees are charged on top of the bridged amount, not deducted from it.
 *      - `quotes[0].token == address(0)` carries the native dispatch fee (mailbox + IGP).
 *        Pay the gateway as `msg.value`.
 *      - `quotes[1]` (when present, ERC20 routes only) carries the warp route's required
 *        token-leg amount including any internal fee — pre-`approve` exactly this value.
 *      - `transferRemote` returns nothing; the Hyperlane `messageId` is observed
 *        off-chain by indexing the `Mailbox.DispatchId(bytes32)` event from the same tx.
 */
interface ITokenBridge {
    function transferRemote(uint32 _destination, bytes32 _recipient, uint256 _amount)
        external
        payable
        returns (bytes32 messageId);

    struct Quote {
        address token;
        uint256 amount;
    }

    function quoteTransferRemote(uint32 _destination, bytes32 _recipient, uint256 _amount)
        external
        view
        returns (Quote[] memory quotes);
}
