// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MerkleTree} from "../libraries/MerkleTree.sol";

interface IRollupErrors {
    /**
     * @notice Error thrown when the rollup is corrupted.
     */
    error RollupCorrupted();
    /**
     * @notice Error thrown when the previous block hash is wrong.
     */
    error WrongPreviousBlockHash(bytes32 expected, bytes32 provided);
    /**
     * @notice Error thrown when the deposit verification failed.
     */
    error DepositVerificationFailed(bytes32 blockHash);
    /**
     * @notice Error thrown when the accept deposit deadline exceeded.
     */
    error AcceptDepositDeadlineExceeded(uint256 deadline, uint256 currentBlock);
    /**
     * @notice Error thrown when the batch is not accepted.
     */
    error BatchNotAccepted(uint256 batchIndex);
    error BatchAlreadyFinalized(uint256 batchIndex);
    error BlockCommitmentAlreadyProofed(bytes32 commitmentHash);
    error BatchAlreadyChallenged(uint256 batchIndex);
    error IncorrectChallengeDeposit(uint256 required, uint256 provided);
    error EthTransferFailed(address recipient, uint256 amount);
    error InvalidRevertIndex(uint256 index);
    error BlockHashMismatch(bytes32 expected, bytes32 provided);
    error InvalidBatchIndex(uint256 providedBatchIndex, uint256 currentBatchIndex);
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
    error InvalidNitroSignature();
    error InvalidSP1Proof();
    error NitroVerifierNotSet();
    error InsufficientGas();
    error InvalidBatchStatus(uint256 batchIndex, uint8 current);
    error BlockCommitmentAlreadyChallenged(bytes32 commitmentHash);
    error BlockCommitmentNotChallenged(bytes32 commitmentHash);
    error NitroVerifierNotEnabled(address nitroVerifier);

    error NextBatchIndexOverflow();
}

interface IRollupEvents {
    event VerifierUpdated(address indexed oldVerifier, address indexed newVerifier);

    event DaCheckUpdated(bool oldValue, bool newValue);

    event BridgeUpdated(address indexed oldBridge, address indexed newBridge);

    event ProgramVKeyUpdated(bytes32 indexed oldValue, bytes32 indexed newValue);
    event NitroVerifierUpdated(address indexed oldVerifier, address indexed newVerifier);

    event BatchAccepted(uint256 batchIndex, bytes32 batchRoot);
    event BatchPreConfirmed(uint256 batchIndex);
    event BatchFinalized(uint256 batchIndex);

    event BlockCommitmentChallenged(uint256 batchIndex, bytes32 commitmentHash, address indexed challenger);
    event BlockCommitmentProved(uint256 batchIndex, bytes32 commitmentHash, address indexed prover);

    event ForceRevertBatch(uint256 batchIndex);

    event ChallengeDepositWithdrawn(address indexed challenger, uint256 amount);

    event ProofRewardWithdrawn(address indexed prover, uint256 amount);
}

interface IRollupRead {
    /// @notice Returns the challenge queue.
    function getChallengeQueue() external view returns (bytes32[] memory);

    /// @notice Checks if rollup is corrupted.
    function rollupCorrupted() external view returns (bool);

    /// @notice Checks if a batch has been accepted.
    ///  function acceptedBatch(uint256 _batchIndex) external view returns (bool);

    /// @notice Checks if a batch has been finalized.
    //  function finalizedBatch(uint256 _batchIndex) external view returns (bool);
}

interface IRollupWrite {
    /// @notice Forces reversion of batches starting from a given index.
    function forceRevertBatch(uint256 _revertedBatchIndex) external payable;

    /// @notice Ensures a batch is marked as finalized if eligible.
    function ensureBatchFinalized(uint256 _batchIndex) external returns (bool);

    /// @notice Withdraws the challenge deposit and incentive (if any) for a given challenger.
    function withdrawChallengeDeposit(address payable challenger) external payable;

    /// @notice Withdraws pending proof reward for the caller.
    function withdrawProofReward() external;
}

interface IRollup is IRollupRead, IRollupWrite {}
