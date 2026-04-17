// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {BatchRecord, BatchStatus} from "../../contracts/interfaces/rollup/IRollupTypes.sol";

contract MockRollup {
    bool public finalized;
    bool public corrupted;
    mapping(uint256 => bytes32) public batchRoots;

    function setFinalized(bool value) external {
        finalized = value;
    }

    function setCorrupted(bool value) external {
        corrupted = value;
    }

    function setBatchRoot(uint256 batchIndex, bytes32 root) external {
        batchRoots[batchIndex] = root;
    }

    function isBatchFinalized(uint256) external view returns (bool) {
        return finalized;
    }

    function isRollupCorrupted() external view returns (bool) {
        return corrupted;
    }

    function getBatch(uint256 batchIndex) external view returns (BatchRecord memory) {
        return
            BatchRecord({
                batchRoot: batchRoots[batchIndex],
                acceptedAtBlock: 0,
                expectedBlobs: 0,
                status: finalized ? BatchStatus.Finalized : BatchStatus.None,
                sentMessageCursorStart: 0,
                submitBlobsWindowSnapshot: 0,
                preconfirmationWindowSnapshot: 0,
                challengeWindowSnapshot: 0,
                finalizationDelaySnapshot: 0,
                numberOfBlocks: 0
            });
    }
}
