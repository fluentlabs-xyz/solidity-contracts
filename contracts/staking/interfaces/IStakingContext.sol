// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.30;

interface IStakingContextErrors {
    /**
     * @notice Thrown when the amount is too low.
     * @param amount The amount that is too low.
     */
    error AmountTooLow(uint256 amount);
    /**
     * @notice Thrown when the commission rate is bad.
     * @param commissionRate The commission rate that is bad.
     */
    error BadCommissionRate(uint16 commissionRate);
    /**
     * @notice Thrown when the input length is malformed.
     */
    error MalformedInputLength();
    /**
     * @notice Thrown when the share distribution is bad.
     * @param shareDistribution The share distribution that is bad.
     */
    error BadShareDistribution(uint16 shareDistribution);
    /**
     * @notice Thrown when the deposit is zero.
     */
    error DepositIsZero();
    /**
     * @notice Thrown when the delegation queue is empty.
     */
    error DelegationQueueEmpty();
    /**
     * @notice Thrown when the delegation queue is not empty.
     * @param delegationQueue The delegation queue that is not empty.
     */
    error DelegationQueueNotEmpty(uint256 delegationQueue);
    /**
     * @notice Thrown when the initial balance is malformed.
     */
    error MalformedInitialBalance();
    /**
     * @notice Thrown when the initial stake is too low.
     * @param initialStake The initial stake that is too low.
     */
    error InitialStakeTooLow(uint256 initialStake);
    /**
     * @notice Thrown when the balance is insufficient.
     */
    error InsufficientBalance();
    /**
     * @notice Thrown when the claim epoch is invalid.
     */
    error InvalidClaimEpoch();
    /**
     * @notice Thrown when the validator is not active.
     */
    error NotActiveValidator();
    /**
     * @notice Thrown when the balance is not enough.
     */
    error NotEnoughBalance();
    /**
     * @notice Thrown when the shares are not enough.
     * @param requiredShares The shares that are not enough.
     */
    error NotEnoughShares(uint256 requiredShares);
    /**
     * @notice Thrown when the validator is not pending.
     * @param validator The validator that is not pending.
     */
    error NotPendingValidator(address validator);
    /**
     * @notice Thrown when the epoch is not ready.
     * @param epoch The epoch that is not ready.
     */
    error EpochIsNotReady(uint64 epoch);
    /**
     * @notice Thrown when there is nothing to claim.
     */
    error NothingToClaim();
    /**
     * @notice Thrown when there is nothing to unstake.
     */
    error NothingToUnstake();
    /**
     * @notice Thrown when the sender is not the coinbase.
     */
    error OnlyCoinbase();
    /**
     * @notice Thrown when the sender is not the governance.
     */
    error OnlyGovernance();
    /**
     * @notice Thrown when the sender is not the slashing indicator.
     */
    error OnlySlashingIndicator();
    /**
     * @notice Thrown when the sender is not the staking contract.
     */
    error OnlyStakingContract();
    /**
     * @notice Thrown when the sender is not the validator owner.
     * @param validator The validator that is not the owner.
     */
    error OnlyValidatorOwner(address validator);
    /**
     * @notice Thrown when the sender is not the zero gas price.
     */
    error OnlyZeroGasPrice();
    /**
     * @notice Thrown when the pending undelegate is not found.
     */
    error PendingUndelegate();
    /**
     * @notice Thrown when the safe transfer failed.
     */
    error SafeTransferFailed();
    /**
     * @notice Thrown when the sender is still in jail.
     * @param validator The validator that is still in jail.
     */
    error StillInJail(address validator);
    error UnsafeTransferFailed();
    /**
     * @notice Thrown when the validator already exists.
     * @param validator The validator that already exists.
     */
    error ValidatorAlreadyExists(address validator);
    /**
     * @notice Thrown when the validator is not found.
     * @param validator The validator that is not found.
     */
    error ValidatorNotFound(address validator);
    /**
     * @notice Thrown when the validator is not in jail.
     * @param validator The validator that is not in jail.
     */
    error ValidatorNotInJail(address validator);
    /**
     * @notice Thrown when the validator owner is already in use.
     * @param validator The validator that is already in use.
     */
    error ValidatorOwnerAlreadyInUse(address validator);
    error WrongAmountPrecision();
    /**
     * @notice Thrown when the amount is zero.
     */
    error ZeroAmount();
    /**
     * @notice Thrown when the owner is zero.
     */
    error OwnerCantBeZero();
    /**
     * @notice Thrown when consensus keys are already set for the validator.
     * @param validator The validator whose keys are already set.
     */
    error ConsensusKeysAlreadySet(address validator);
    /**
     * @notice Thrown when consensus keys are not set for the validator.
     * @param validator The validator whose keys are not set.
     */
    error ConsensusKeysNotSet(address validator);
    /**
     * @notice Thrown when the epoch committee has not been committed.
     * @param epoch The epoch with no committed committee.
     */
    error EpochCommitteeNotCommitted(uint64 epoch);
    /**
     * @notice Thrown when a Simplex signer index is out of the committee range.
     */
    error SignerIndexOutOfRange(uint64 epoch, uint32 signerIdx, uint256 committeeLen);
    /**
     * @notice Thrown when the submitted committee length does not match the keyed top-k set.
     */
    error CommitteeLengthMismatch(uint256 expected, uint256 got);
    /**
     * @notice Thrown when a committee member has no consensus (peer) key.
     * @param validator The keyless committee member.
     */
    error CommitteeMemberKeyless(address validator);
    /**
     * @notice Thrown when a committee member is not in the active set.
     * @param validator The non-active committee member.
     */
    error CommitteeMemberNotInActiveSet(address validator);
    /**
     * @notice Thrown when the committee is not in strictly ascending peerPubkey order.
     * @param validator The member breaking the ordering.
     */
    error CommitteeNotStrictlyAscending(address validator);
    /**
     * @notice Thrown when the validator was already slashed for an equivocation.
     * @param validator The tombstoned validator.
     */
    error AlreadySlashedForEquivocation(address validator);
    /**
     * @notice Thrown when an equivocation signature fails verification or binding.
     */
    error EquivocationSignatureInvalid();
    /**
     * @notice Thrown when the supplied pubkey does not bind to the registered key.
     */
    error EquivocationKeyMismatch();
    /**
     * @notice Thrown when the BLS verifier address is not configured.
     */
    error BlsVerifierNotConfigured();
    /**
     * @notice Thrown when the on-chain Proof-of-Possession fails.
     * @param validator The validator whose PoP is invalid.
     */
    error InvalidProofOfPossession(address validator);
    /**
     * @notice Thrown when consensus key encoding (uncompressed lengths) is invalid.
     */
    error InvalidConsensusKeyEncoding();
}
