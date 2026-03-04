// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {RollupStorageLayout} from "../../contracts/rollup/RollupStorage.sol";

contract RollupHandler {
    bytes32 internal constant ZERO_HASH = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    Rollup public rollup;
    uint256 public illegalNextBatchDecreaseCount;

    uint256 internal entropyNonce;
    RollupStorageLayout.BlockCommitment[] internal trackedCommitments;
    uint256[] internal trackedBatchIndexes;
    bytes32[] internal trackedCommitmentHashes;

    receive() external payable {}

    function initialize(Rollup _rollup) external {
        require(address(rollup) == address(0), "already initialized");
        rollup = _rollup;
    }

    function commitmentsLength() external view returns (uint256) {
        return trackedCommitmentHashes.length;
    }

    function commitmentHashAt(uint256 index) external view returns (bytes32) {
        return trackedCommitmentHashes[index];
    }

    function stepAcceptBatch(uint256 salt) external {
        uint256 beforeIndex = rollup.nextBatchIndex();
        if (beforeIndex == 0) {
            return;
        }

        bytes32 prevHash = rollup.lastBlockHashInBatch(beforeIndex - 1);
        bytes32 blockHash = keccak256(abi.encodePacked(address(this), entropyNonce++, salt));

        RollupStorageLayout.BlockCommitment[] memory batch = new RollupStorageLayout.BlockCommitment[](1);
        batch[0] = RollupStorageLayout.BlockCommitment({
            previousBlockHash: prevHash,
            blockHash: blockHash,
            withdrawalHash: ZERO_HASH,
            depositHash: ZERO_HASH
        });

        try rollup.acceptNextBatch(batch, new RollupStorageLayout.DepositsInBlock[](0), 0) {
            trackedCommitments.push(batch[0]);
            trackedBatchIndexes.push(beforeIndex);
            trackedCommitmentHashes.push(
                keccak256(abi.encodePacked(batch[0].previousBlockHash, batch[0].blockHash, batch[0].withdrawalHash, batch[0].depositHash))
            );
        } catch {}
        _recordNextBatchDecrease(beforeIndex, false);
    }

    function stepChallenge(uint256 seed) external {
        uint256 beforeIndex = rollup.nextBatchIndex();
        uint256 len = trackedCommitments.length;
        if (len == 0) {
            return;
        }

        uint256 index = seed % len;
        bytes32 commitmentHash = trackedCommitmentHashes[index];
        if (rollup.blockCommitmentChallenger(commitmentHash) != address(0) || rollup.provenBlockCommitment(commitmentHash)) {
            return;
        }

        MerkleTree.MerkleProof memory blockProof = MerkleTree.MerkleProof({nonce: 0, proof: ""});

        try
            rollup.challengeBlockCommitment{value: rollup.challengeDepositAmount()}(
                trackedBatchIndexes[index],
                trackedCommitments[index],
                blockProof
            )
        {} catch {}
        _recordNextBatchDecrease(beforeIndex, false);
    }

    function stepProve(uint256 seed) external {
        uint256 beforeIndex = rollup.nextBatchIndex();
        uint256 len = trackedCommitments.length;
        if (len == 0) {
            return;
        }

        uint256 index = seed % len;
        MerkleTree.MerkleProof memory blockProof = MerkleTree.MerkleProof({nonce: 0, proof: ""});

        try rollup.proofBlockCommitment(trackedBatchIndexes[index], trackedCommitments[index], 0, hex"1234", blockProof) {} catch {}
        _recordNextBatchDecrease(beforeIndex, false);
    }

    function stepForceRevert(uint256 seed) external {
        uint256 beforeIndex = rollup.nextBatchIndex();
        if (beforeIndex <= 1) {
            return;
        }

        uint256 revertIndex = 1 + (seed % (beforeIndex - 1));

        try rollup.forceRevertBatch(revertIndex) {} catch {}
        _recordNextBatchDecrease(beforeIndex, true);
    }

    function stepWithdrawChallengeDeposit() external {
        uint256 beforeIndex = rollup.nextBatchIndex();
        try rollup.withdrawChallengeDeposit(payable(address(this))) {} catch {}
        _recordNextBatchDecrease(beforeIndex, false);
    }

    function stepWithdrawProofReward() external {
        uint256 beforeIndex = rollup.nextBatchIndex();
        (bool success, ) = address(rollup).call(abi.encodeWithSelector(bytes4(keccak256("withdrawProofReward()"))));
        success;
        _recordNextBatchDecrease(beforeIndex, false);
    }

    function _recordNextBatchDecrease(uint256 beforeIndex, bool isForceRevert) internal {
        uint256 afterIndex = rollup.nextBatchIndex();
        if (afterIndex < beforeIndex && !isForceRevert) {
            illegalNextBatchDecreaseCount += 1;
        }
    }
}
