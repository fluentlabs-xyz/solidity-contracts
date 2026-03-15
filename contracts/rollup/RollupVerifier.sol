// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MerkleTree} from "../libraries/MerkleTree.sol";
import {RollupStorageLayout} from "./RollupStorageLayout.sol";
import {IVerifier} from "../interfaces/IVerifier.sol";
import {INitroEnclaveVerifier} from "../interfaces/INitroEnclaveVerifier.sol";
import {L2BlockHeader} from "../interfaces/IRollup.sol";

abstract contract RollupVerifier is RollupStorageLayout {
    /// @dev Computes the commitment hash for an L2 block header.
    function _computeCommitment(L2BlockHeader calldata header) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(header.previousBlockHash, header.blockHash, header.withdrawalRoot, header.depositRoot));
    }

    /// @dev Verifies commitment against batch root, then verifies Nitro + SP1 proofs.
    function _verifyAndResolve(
        uint256 batchIndex,
        L2BlockHeader calldata blockHeader,
        MerkleTree.MerkleProof calldata blockProof,
        address nitroVerifier,
        bytes32 nitroSignature,
        bytes calldata sp1Proof
    ) internal view returns (bytes32) {
        RollupStorage storage $ = _getRollupStorage();

        bytes32 commitment = _computeCommitment(blockHeader);

        require($.challenges[commitment].batchIndex != 0, BlockNotChallenged(commitment));
        require(!$.provenBlocks[commitment], BlockAlreadyProven(commitment));
        require(
            MerkleTree.verifyMerkleProof($.batches[batchIndex].batchRoot, commitment, blockProof.nonce, blockProof.proof),
            InvalidBlockProof()
        );

        _verifyNitroAndSp1(batchIndex, blockHeader, nitroVerifier, nitroSignature, sp1Proof);

        return commitment;
    }

    /// @dev Verifies both Nitro and SP1 proofs for a block.
    function _verifyNitroAndSp1(
        uint256 batchIndex,
        L2BlockHeader calldata blockHeader,
        address nitroVerifier,
        bytes32 nitroSignature,
        bytes calldata sp1Proof
    ) internal view {
        RollupStorage storage $ = _getRollupStorage();
        bytes32[] memory blobHashes = $.batchBlobHashes[batchIndex];

        require(_proveBlockWithNitro(nitroVerifier, blockHeader, nitroSignature, blobHashes), InvalidNitroSignature());

        _proveBlockWithSp1(sp1Verifier(), blobHashes, blockHeader, sp1Proof);
    }

    /// @dev Proves a batch with Nitro enclave signature.
    function _proveBatchWithNitro(
        address verifier,
        bytes32 batchRoot,
        bytes32[] memory blobHashes,
        bytes32 signature
    ) internal view returns (bool) {
        RollupStorage storage $ = _getRollupStorage();
        require($.enabledNitroVerifiers[verifier], NitroVerifierNotEnabled(verifier));
        require(INitroEnclaveVerifier(verifier).isAttestationVerified(), InvalidNitroSignature());
        return INitroEnclaveVerifier(verifier).verifyBatch(batchRoot, blobHashes, signature);
    }

    /// @dev Proves an L2 block with Nitro enclave signature.
    function _proveBlockWithNitro(
        address verifier,
        L2BlockHeader calldata header,
        bytes32 signature,
        bytes32[] memory blobHashes
    ) internal view returns (bool) {
        RollupStorage storage $ = _getRollupStorage();
        require($.enabledNitroVerifiers[verifier], NitroVerifierNotEnabled(verifier));
        require(INitroEnclaveVerifier(verifier).isAttestationVerified(), InvalidNitroSignature());
        return
            INitroEnclaveVerifier(verifier).verifyBlock(
                header.previousBlockHash,
                header.blockHash,
                header.withdrawalRoot,
                header.depositRoot,
                signature,
                blobHashes
            );
    }

    /// @dev Proves an L2 block header with SP1 ZK proof. Reverts on invalid proof.
    function _proveBlockWithSp1(
        address verifier,
        bytes32[] memory blobHashes,
        L2BlockHeader calldata header,
        bytes memory sp1Proof
    ) internal view {
        bytes memory publicValues = _getPublicValuesFromHeaderAndBlobs(header, blobHashes);
        IVerifier(verifier).verifyProof(_getRollupStorage().programVKey, publicValues, sp1Proof);
    }
}
