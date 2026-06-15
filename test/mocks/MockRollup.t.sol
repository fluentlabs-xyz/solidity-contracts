// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockRollup} from "../../contracts/mocks/MockRollup.sol";
import {RollupStorageLayout} from "../../contracts/rollup/RollupStorageLayout.sol";
import {BatchRecord} from "../../contracts/interfaces/rollup/IRollupTypes.sol";

contract MockRollupTest is Test {
    MockRollup internal mock;

    function setUp() public {
        mock = new MockRollup();
    }

    /// The mock exists ONLY to stand in for the real read path: its getter
    /// selectors must be byte-identical to RollupStorageLayout's, or the
    /// cert-follower client would pass against the mock and fail on prod.
    function test_SelectorsMatchRealRollup() public pure {
        assertEq(
            MockRollup.lastFinalizedBatchIndex.selector,
            RollupStorageLayout.lastFinalizedBatchIndex.selector
        );
        assertEq(MockRollup.getBatch.selector, RollupStorageLayout.getBatch.selector);
    }

    function test_SetCheckpointRoundTrip() public {
        bytes32 h = keccak256("block-1024");
        mock.setCheckpoint(3, h);
        assertEq(mock.lastFinalizedBatchIndex(), 3);
        BatchRecord memory batch = mock.getBatch(3);
        assertEq(batch.toBlockHash, h);
    }

    function test_UnsetBatchIsZero() public view {
        assertEq(mock.getBatch(7).toBlockHash, bytes32(0));
    }
}
