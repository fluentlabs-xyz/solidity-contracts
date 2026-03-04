// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MerkleTree} from "../libraries/MerkleTree.sol";

interface IRollupErrors {
    error RollupCorrupted();
    error WrongPreviousBlockHash(bytes32 expected, bytes32 provided);
    error DepositVerificationFailed(bytes32 blockHash);
    error AcceptDepositDeadlineExceeded(uint256 deadline, uint256 currentBlock);
    error BatchNotAccepted(uint256 batchIndex);
    error BatchAlreadyApproved(uint256 batchIndex);
    error BlockCommitmentAlreadyProofed(bytes32 commitmentHash);
    error BatchAlreadyChallenged(uint256 batchIndex);
    error InsufficientChallengeDeposit(uint256 required, uint256 provided);
    error ExcessiveChallengeDeposit(uint256 required, uint256 provided);
    error EthTransferFailed(address recipient, uint256 amount);
    error InvalidRevertIndex(uint256 index);
    error BlockHashMismatch(bytes32 expected, bytes32 provided);
    error InvalidBatchIndex(uint256 expected, uint256 provided);
    error InvalidBatchSize(uint256 expected, uint256 provided);
    error InvalidBlockSequence(uint256 index, bytes32 currentHash, bytes32 nextPrevHash);
    error InvalidDepositsArrayLength();
    error NoLeavesProvided();
    error NothingToWithdraw();
    error NotEnoughValueIncentiveFee(uint256 value, uint256 incentiveFee);
    error InvalidBlockProof();
    error ContractPaused();
    error DaBlobHashMismatch(bytes32 expected, bytes32 provided);
    error ZeroAddressNotAllowed(string field);
    error ZeroValueNotAllowed(string field);
    error OnlySequencer();
}

interface IRollupEvents {
    event UpdateVerifier(address oldVerifier, address newVerifier);
    event BatchAccepted(uint256 batchIndex, bytes32 batchRoot);
    event BatchProofed(uint256 batchIndex);
    event ForceRevertBatch(uint256 batchIndex);
    event ChallengeDepositWithdrawn(address indexed challenger, uint256 amount);
    event ProofRewardWithdrawn(address indexed prover, uint256 amount);
    event DaCheckUpdated(bool oldValue, bool newValue);
    event BridgeUpdated(address indexed oldBridge, address indexed newBridge);
}

interface IRollup is IRollupErrors, IRollupEvents {
    /// @notice Address of the sequencer. Responsible for accepting new batches.
    function sequencer() external view returns (address);

    /// @notice Address of the Bridge contract.
    function bridge() external view returns (address);

    /// @notice Program verification key for SP1 proof verification.
    function programVKey() external view returns (bytes32);

    /// @notice Next batch index to be accepted.
    function nextBatchIndex() external view returns (uint256);

    /// @notice Number of blocks in each batch.
    function batchSize() external view returns (uint256);

    /// @notice Mapping from batch index to batch root hash.
    function acceptedBatchHash(uint256 batchIndex) external view returns (bytes32);

    /// @notice Returns the last block hash in a given batch.
    function lastBlockHashInBatch(uint256 batchIndex) external view returns (bytes32);

    /// @notice Mapping from batch index to the verified blob hashes used for data availability.
    function batchBlobHashes(uint256 batchIndex) external view returns (bytes32[] memory);

    /// @notice Toggle data availability check.
    function setDaCheck(bool isCheck) external payable;

    /// @notice Set a new bridge contract address.
    function setBridge(address _bridge) external payable;

    /// @notice Updates the verifier contract.
    function updateVerifier(address _newVerifier) external;

    /// @notice Pauses the contract, preventing all non-owner functions from being called.
    function pause() external;

    /// @notice Unpauses the contract, allowing all functions to be called again.
    function unpause() external;

    /// @notice Forces reversion of batches starting from a given index.
    function forceRevertBatch(uint256 _revertedBatchIndex) external payable;

    /// @notice Returns the challenge queue.
    function getChallengeQueue() external view returns (bytes32[] memory);

    /// @notice Checks if rollup is corrupted.
    function rollupCorrupted() external view returns (bool);

    /// @notice Checks if a batch has been accepted.
    function acceptedBatch(uint256 _batchIndex) external view returns (bool);

    /// @notice Checks if a batch has been approved.
    function approvedBatch(uint256 _batchIndex) external view returns (bool);

    /// @notice Ensures a batch is marked as approved if eligible.
    function ensureBatchApproved(uint256 _batchIndex) external returns (bool);

    /// @notice Withdraws the challenge deposit and incentive (if any) for a given challenger.
    function withdrawChallengeDeposit(address payable challenger) external payable;

    /// @notice Withdraws pending proof reward for the caller.
    function withdrawProofReward() external;
}
