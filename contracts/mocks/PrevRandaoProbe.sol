// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/**
 * @title PrevRandaoProbe
 * @dev Smoke-only probe for the DPoS randomness beacon. Surfaces the
 * EVM-visible `block.prevrandao` so the VRF smoke can assert it equals the
 * block's header `mixHash` — i.e. the beacon value `H(seed)` actually reached
 * EVM execution, not merely the header. Not a production contract.
 */
contract PrevRandaoProbe {
    /// Emitted by {snapshot} so a tx receipt pins `prevrandao` to a block.
    event Snapshot(uint256 indexed blockNumber, uint256 prevrandao);

    /// The latest/pending block's `prevrandao`, for a `cast call`.
    function currentPrevrandao() external view returns (uint256) {
        return block.prevrandao;
    }

    /// Records the executing block's `prevrandao` in an event + return value,
    /// so a tx receipt binds `prevrandao` to a concrete block number that the
    /// smoke can compare against that block's header `mixHash`.
    function snapshot() external returns (uint256 r) {
        r = block.prevrandao;
        emit Snapshot(block.number, r);
    }
}
