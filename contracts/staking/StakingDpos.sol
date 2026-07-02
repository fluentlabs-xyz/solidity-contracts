// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStaking, IStakingEvents} from "./interfaces/IStaking.sol";
import {IStakingContextErrors} from "./interfaces/IStakingContext.sol";
import {IChainConfig} from "./interfaces/IChainConfig.sol";
import {IBLS12381Verifier} from "./interfaces/IBLS12381Verifier.sol";
import {SimplexEvidenceDecoder} from "../libraries/SimplexEvidenceDecoder.sol";
import {StakingLayout} from "./StakingLayout.sol";

/// @title DPoS consensus extraction library
/// @author Fluent Labs
/// @notice Heavy, rarely-called DPoS-consensus logic (consensus-key
///         registration and equivocation slashing) relocated out of `Staking`
///         to keep its runtime bytecode under the EIP-170 24 KB limit. Reached
///         by DELEGATECALL from `Staking`'s thin forwarders, so it shares the
///         proxy's `msg.sender`, `address(this)`, and ERC-7201 storage.
/// @dev Library code under DELEGATECALL reads its OWN (empty) immutables, so it
///      cannot see `Staking`'s `_chainConfigContract` — the dependency is
///      threaded in as the `cfg` parameter. Errors live in
///      `IStakingContextErrors`; events are emitted via `IStakingEvents`.
library StakingDpos {
    using SafeERC20 for IERC20;

    /// @notice BLS signature DST (MinSig MESSAGE) — distinct from PoP's DST.
    bytes private constant BLS_SIG_DST = "BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_POP_";

    /// @notice BLS PoP DST (MinSig PROOF_OF_POSSESSION) — distinct from BLS_SIG_DST.
    bytes private constant BLS_POP_DST = "BLS_POP_BLS12381G1_XMD:SHA-256_SSWU_RO_POP_";

    /// @notice Expected length of a compressed BLS12-381 G2 pubkey (MinSig variant).
    uint256 internal constant BLS_PUBKEY_LENGTH = 96;

    /// @notice Burn sink for the non-reporter remainder of an equivocation seizure. A
    ///         standard ERC20 `transfer` to address(0) reverts, so the canonical dead
    ///         address is used instead; no key controls it, so the tokens are permanently
    ///         removed from circulation. (The reporter's cut, in basis points, is a
    ///         governance-configurable `ChainConfig.getSlashReporterRewardBps()`.)
    address internal constant EQUIVOCATION_BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    /// @notice Safety margin (in epochs) added to the undelegate period when
    ///         retaining frozen committees.
    uint64 internal constant EPOCH_COMMITTEE_RETENTION_MARGIN = 8;

    /// @dev Epoch math at an arbitrary block, mirroring `Staking._currentEpoch`.
    ///      `cfg` is passed in because immutables are not reachable under
    ///      DELEGATECALL. Single source of the relative-epoch formula; reused by
    ///      `LivenessSlashing.processBitmap` so the window check and the commit
    ///      cursor can never disagree on epoch numbering.
    function _epochAt(IChainConfig cfg, uint256 blockNumber) internal view returns (uint64) {
        uint64 activation = cfg.getDposActivationBlock();
        if (blockNumber < activation) {
            return 0;
        }
        return uint64((blockNumber - activation) / cfg.getEpochBlockInterval());
    }

    function _currentEpoch(IChainConfig cfg) internal view returns (uint64) {
        return _epochAt(cfg, block.number);
    }

    function _nextEpoch(IChainConfig cfg) internal view returns (uint64) {
        return _currentEpoch(cfg) + 1;
    }

    /// @notice Register consensus keys for `validator` with on-chain
    ///         Proof-of-Possession. One-shot — no rotation in v1.
    /// @param blsPubkeyUncompressed 256 B EIP-2537 G2 — compressed on-chain
    ///                              to the stored 96 B identity.
    /// @param blsPoPUncompressed    128 B EIP-2537 G1 PoP signature — verify-only.
    function setConsensusKeys(
        IChainConfig cfg,
        address validatorAddress,
        bytes calldata blsPubkeyUncompressed,
        bytes calldata blsPoPUncompressed,
        bytes32 peerPubkey
    ) external {
        if (StakingLayout.equivocationStorage().tombstoned[validatorAddress]) {
            revert IStakingContextErrors.AlreadySlashedForEquivocation(validatorAddress);
        }
        StakingLayout.StakingStorage storage $s = StakingLayout.stakingStorage();
        IStaking.Validator memory v = $s._validatorsMap[validatorAddress];
        if (v.status == IStaking.ValidatorStatus.NotFound) {
            revert IStakingContextErrors.ValidatorNotFound(validatorAddress);
        }
        if (msg.sender != v.ownerAddress) revert IStakingContextErrors.OnlyValidatorOwner(v.ownerAddress);
        if (blsPubkeyUncompressed.length != 256 || blsPoPUncompressed.length != 128) {
            revert IStakingContextErrors.InvalidConsensusKeyEncoding();
        }
        // Reject zero peerPubkey: combined with the no-rotation rule this
        // would self-brick the validator (forever absent from any committee
        // because byte-lex sort would never produce a slot for `bytes32(0)`).
        if (peerPubkey == bytes32(0)) revert IStakingContextErrors.InvalidConsensusKeyEncoding();

        StakingLayout.ConsensusKeysStorage storage $ck = StakingLayout.consensusKeysStorage();
        if ($ck.consensusKeys[validatorAddress].blsPubkey.length != 0) {
            revert IStakingContextErrors.ConsensusKeysAlreadySet(validatorAddress);
        }
        // Global peerPubkey uniqueness (mirrors ValidatorOwnerAlreadyInUse): a
        // duplicate would make `commitEpochCommittee` permanently unsatisfiable.
        if ($ck.peerPubkeyOwner[peerPubkey] != address(0)) {
            revert IStakingContextErrors.PeerPubkeyAlreadyInUse(peerPubkey);
        }

        address verifierAddr = cfg.getBlsVerifier();
        if (verifierAddr == address(0)) revert IStakingContextErrors.BlsVerifierNotConfigured();
        IBLS12381Verifier verifier = IBLS12381Verifier(verifierAddr);

        // Derive the authoritative compressed identity on-chain: it becomes
        // BOTH the PoP signed message and the stored key. No compare — PoP
        // self-proves possession; there is no pre-existing anchor at
        // registration. PoP: namespace = base fluent_namespace (NO subject
        // suffix); DST = BLS_POP_… ; one G1 sig.
        bytes memory blsPubkey = verifier.compressG2Unchecked(blsPubkeyUncompressed);

        if (!verifier.verify(_fluentNamespace(), blsPubkey, BLS_POP_DST, blsPoPUncompressed, blsPubkeyUncompressed)) {
            revert IStakingContextErrors.InvalidProofOfPossession(validatorAddress);
        }

        uint64 activationEpoch = _nextEpoch(cfg);
        $ck.consensusKeys[validatorAddress] =
            IStaking.ConsensusKeys({blsPubkey: blsPubkey, peerPubkey: peerPubkey, activationEpoch: activationEpoch});
        $ck.peerPubkeyOwner[peerPubkey] = validatorAddress;

        emit IStakingEvents.ConsensusKeysSet(validatorAddress, blsPubkey, peerPubkey, activationEpoch);
    }

    /// @dev fluent_namespace(chain_id) = "FLUENT_DPOS_V1_" ‖ chain_id u64 BE (23 B).
    ///      `block.chainid` == the Simplex consensus node `chain_id` (cross-component
    ///      invariant; the conformance corpus uses 20994).
    function _fluentNamespace() internal view returns (bytes memory) {
        return abi.encodePacked(bytes15("FLUENT_DPOS_V1_"), bytes8(uint64(block.chainid)));
    }

    /// @dev Per-subject namespace: base ‖ subject suffix (plain concat, no
    ///      length prefix — mirrors commonware_utils::union).
    function _nsForKind(uint8 kind) internal view returns (bytes memory) {
        bytes memory base = _fluentNamespace();
        if (kind == 0) return bytes.concat(base, "_NOTARIZE");
        if (kind == 1) return bytes.concat(base, "_NULLIFY");
        return bytes.concat(base, "_FINALIZE"); // kind == 2
    }

    function _decoder(IChainConfig cfg) internal view returns (SimplexEvidenceDecoder) {
        address decoderAddr = cfg.getEvidenceDecoder();
        if (decoderAddr == address(0)) revert IStakingContextErrors.EvidenceDecoderNotConfigured();
        return SimplexEvidenceDecoder(decoderAddr);
    }

    function slashEquivocationNotarize(
        IChainConfig cfg,
        IERC20 token,
        bytes calldata evidence,
        bytes calldata pkUncompressed,
        bytes calldata sig1Uncompressed,
        bytes calldata sig2Uncompressed
    ) external {
        _slashEquivocation(
            cfg, token, _decoder(cfg).decodeConflictingNotarize(evidence), pkUncompressed, sig1Uncompressed, sig2Uncompressed
        );
    }

    function slashEquivocationFinalize(
        IChainConfig cfg,
        IERC20 token,
        bytes calldata evidence,
        bytes calldata pkUncompressed,
        bytes calldata sig1Uncompressed,
        bytes calldata sig2Uncompressed
    ) external {
        _slashEquivocation(
            cfg, token, _decoder(cfg).decodeConflictingFinalize(evidence), pkUncompressed, sig1Uncompressed, sig2Uncompressed
        );
    }

    function slashEquivocationNullifyFinalize(
        IChainConfig cfg,
        IERC20 token,
        bytes calldata evidence,
        bytes calldata pkUncompressed,
        bytes calldata sig1Uncompressed,
        bytes calldata sig2Uncompressed
    ) external {
        _slashEquivocation(
            cfg, token, _decoder(cfg).decodeNullifyFinalize(evidence), pkUncompressed, sig1Uncompressed, sig2Uncompressed
        );
    }

    function _slashEquivocation(
        IChainConfig cfg,
        IERC20 token,
        SimplexEvidenceDecoder.Decoded memory ev,
        bytes calldata pkUncompressed,
        bytes calldata sig1Unc,
        bytes calldata sig2Unc
    ) internal {
        // Resolve the Simplex signer index against the frozen committee for the
        // evidence epoch (inlined from `Staking._resolveSignerToValidator`,
        // which stays in `Staking` for the `resolveSigner` view).
        address[] storage c = StakingLayout.epochCommitteeStorage().committee[ev.epoch];
        uint256 n = c.length;
        if (n == 0) revert IStakingContextErrors.EpochCommitteeNotCommitted(ev.epoch);
        if (ev.signerIdx >= n) revert IStakingContextErrors.SignerIndexOutOfRange(ev.epoch, ev.signerIdx, n);
        address validator = c[ev.signerIdx];

        StakingLayout.EquivocationStorage storage $eq = StakingLayout.equivocationStorage();
        if ($eq.tombstoned[validator]) revert IStakingContextErrors.AlreadySlashedForEquivocation(validator); // replay guard

        bytes memory pk96 = StakingLayout.consensusKeysStorage().consensusKeys[validator].blsPubkey;
        if (pk96.length != BLS_PUBKEY_LENGTH) revert IStakingContextErrors.ConsensusKeysNotSet(validator);

        address verifierAddr = cfg.getBlsVerifier();
        if (verifierAddr == address(0)) revert IStakingContextErrors.BlsVerifierNotConfigured();
        IBLS12381Verifier verifier = IBLS12381Verifier(verifierAddr);

        // Bind caller-supplied uncompressed inputs to the trust anchors:
        //  - pk   -> the validator's registered compressed key
        //  - sigN -> the exact 48 B compressed signature inside the evidence
        if (keccak256(verifier.compressG2Unchecked(pkUncompressed)) != keccak256(pk96)) {
            revert IStakingContextErrors.EquivocationKeyMismatch();
        }
        if (
            keccak256(verifier.compressG1Unchecked(sig1Unc)) != keccak256(ev.sig1)
                || keccak256(verifier.compressG1Unchecked(sig2Unc)) != keccak256(ev.sig2)
        ) revert IStakingContextErrors.EquivocationSignatureInvalid();

        bool ok1 = verifier.verify(_nsForKind(ev.kind1), ev.msg1, BLS_SIG_DST, sig1Unc, pkUncompressed);
        bool ok2 = verifier.verify(_nsForKind(ev.kind2), ev.msg2, BLS_SIG_DST, sig2Unc, pkUncompressed);
        if (!ok1 || !ok2) revert IStakingContextErrors.EquivocationSignatureInvalid();

        // CEI: tombstone before any state-changing penalty.
        $eq.tombstoned[validator] = true;
        _penalizeEquivocation(cfg, token, validator);
        emit IStakingEvents.EquivocationSlashed(validator, ev.epoch, msg.sender);
    }

    /// @dev Equivocation is an immediate permanent jail (not the misdemeanor/felony
    ///      liveness counter). V1: additionally seizes 100% of the offender's OWN
    ///      self-stake — delegators are intentionally left untouched.
    function _penalizeEquivocation(IChainConfig cfg, IERC20 token, address validatorAddress) internal {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        IStaking.Validator memory v = $._validatorsMap[validatorAddress];
        if (v.status == IStaking.ValidatorStatus.NotFound) {
            revert IStakingContextErrors.ValidatorNotFound(validatorAddress);
        }
        if (v.status == IStaking.ValidatorStatus.Active) {
            StakingLayout.removeFromActiveList($, validatorAddress);
        }
        v.status = IStaking.ValidatorStatus.Jail;
        // No jailedBefore sentinel: the `tombstoned` flag set by
        // `_slashEquivocation` is the single never-release mechanism —
        // unconditional and first in `releaseValidatorFromJail`.
        $._validatorsMap[validatorAddress] = v;

        _seizeSelfStake(cfg, token, validatorAddress, v.ownerAddress);

        emit IStakingEvents.ValidatorJailed(validatorAddress, _currentEpoch(cfg));
    }

    /// @dev Seize 100% of the offender's OWN bonded self-stake (owner→self delegation):
    ///      30% rewards the reporter (`msg.sender`), 70% is burned. Because only the
    ///      operator's own stake is taken, a self-reporting offender always nets negative
    ///      (loses 100%, recovers ≤30%), so no self-report guard is required.
    ///      DOES NOT touch the validator's `totalDelegated` snapshots or any delegator
    ///      balance: reducing a past snapshot would retroactively change how
    ///      already-accrued rewards were split among delegators. The seized principal's
    ///      tokens already sit in this contract (pulled at delegate time), so moving them
    ///      out while zeroing the owner's claim keeps balance == liabilities. Any pending
    ///      owner UNdelegation is left claimable — v1 seizes only currently-bonded self-stake.
    function _seizeSelfStake(IChainConfig cfg, IERC20 token, address validatorAddress, address ownerAddress)
        internal
    {
        StakingLayout.StakingStorage storage $ = StakingLayout.stakingStorage();
        IStaking.ValidatorDelegation storage selfDelegation = $._validatorDelegations[validatorAddress][ownerAddress];
        uint256 qlen = selfDelegation.delegateQueue.length;
        if (qlen == 0) return; // no self-stake bonded (e.g. governance-added validator)
        uint112 compact = selfDelegation.delegateQueue[qlen - 1].amount;
        if (compact == 0) return;
        uint256 seized = uint256(compact) * StakingLayout.BALANCE_COMPACT_PRECISION;

        // Effects: zero the bonded self-stake so the owner can never reclaim it.
        delete selfDelegation.delegateQueue;
        selfDelegation.delegateGap = 0;

        // Interactions (CEI: tombstone + state above already applied): reporter cut (a
        // governance-set basis-point fraction of the seized amount) to the reporter, the
        // remainder burned.
        uint256 reporterReward = (seized * cfg.getSlashReporterRewardBps()) / 10_000;
        uint256 burned = seized - reporterReward;
        if (reporterReward > 0) token.safeTransfer(msg.sender, reporterReward);
        if (burned > 0) token.safeTransfer(EQUIVOCATION_BURN_SINK, burned);

        emit IStakingEvents.EquivocationStakeSeized(validatorAddress, msg.sender, reporterReward, burned);
    }

    /// @notice Verify/store/prune half of `commitEpochCommittee`. The `Staking`
    ///         forwarder computes `cur`/`target`/`selectionEpoch` and applies the
    ///         snapshot-finality gate; this derives the stake-weighted keyed
    ///         top-k set `top = _getValidatorsAt(selectionEpoch)` and verifies
    ///         the submitted `committee` against it.
    /// @dev The contract does NOT trust the sequencer-supplied `committee`: it
    ///      verifies the array IS the keyed subset of `top`, strictly ascending
    ///      by `peerPubkey`. length + (∈set) + (strictly ascending ⇒ distinct)
    ///      ⇒ by pigeonhole it is exactly the keyed top-k set, canonically
    ///      ordered.
    function commitEpochCommittee(
        IChainConfig cfg,
        address[] calldata committee,
        uint64 target,
        uint64 cur,
        uint64 selectionEpoch
    ) external {
        StakingLayout.EpochCommitteeStorage storage $ec = StakingLayout.epochCommitteeStorage();
        StakingLayout.ConsensusKeysStorage storage $ck = StakingLayout.consensusKeysStorage();

        // Mark the keyed subset of the top-k set AS OF `selectionEpoch` into a
        // transient set; count it.
        address[] memory top = StakingLayout.getValidatorsAt(cfg, selectionEpoch);
        uint256 m = 0;
        for (uint256 i = 0; i < top.length; i++) {
            if ($ck.consensusKeys[top[i]].peerPubkey != bytes32(0)) {
                _tMark(top[i]);
                m++;
            }
        }

        if (committee.length != m) revert IStakingContextErrors.CommitteeLengthMismatch(m, committee.length);
        address[] storage stored = $ec.committee[target];
        bytes32 prev = bytes32(0);
        for (uint256 i = 0; i < committee.length; i++) {
            address v = committee[i];
            bytes32 peer = $ck.consensusKeys[v].peerPubkey;
            if (peer == bytes32(0)) revert IStakingContextErrors.CommitteeMemberKeyless(v);
            if (!_tMarked(v)) revert IStakingContextErrors.CommitteeMemberNotInActiveSet(v);
            if (peer <= prev) revert IStakingContextErrors.CommitteeNotStrictlyAscending(v);
            _tUnmark(v); // consume → a duplicate address fails _tMarked next time
            prev = peer;
            stored.push(v);
        }
        $ec.lastCommittedEpochP1 = target + 1;

        // Prune relative to the CURRENT epoch (the real retention horizon), not the
        // future `target` being committed. Cursor-based prune advances even across
        // skipped commits; per-call delete count is gas-capped.
        _pruneStaleCommittees(cfg, $ec, cur);

        emit IStakingEvents.EpochCommitteeCommitted(target, committee);
    }

    /// @dev Bounded prune of every retained-window-expired epoch since the
    ///      last prune cursor (handles skipped commits without leaking).
    function _pruneStaleCommittees(IChainConfig cfg, StakingLayout.EpochCommitteeStorage storage $ec, uint64 epoch)
        private
    {
        uint64 retention = uint64(cfg.getUndelegatePeriod()) + EPOCH_COMMITTEE_RETENTION_MARGIN;
        if (epoch <= retention) return;
        uint64 pruneTo = epoch - retention - 1; // newest epoch now outside the window
        uint64 from = $ec.prunedUpToP1; // already-pruned through (from - 1)
        uint64 maxDeletes = 16; // gas cap
        uint64 deleted = 0;
        while (from <= pruneTo && deleted < maxDeletes) {
            if ($ec.committee[from].length != 0) {
                delete $ec.committee[from];
            }
            from++;
            deleted++;
        }
        $ec.prunedUpToP1 = from;
    }

    // Transient membership set (EIP-1153; evm_version=prague). Keyed by raw
    // address — no other transient storage exists in this contract, so there
    // is no slot collision. Auto-clears at end of tx.
    function _tMark(address a) private {
        assembly {
            tstore(a, 1)
        }
    }

    function _tUnmark(address a) private {
        assembly {
            tstore(a, 0)
        }
    }

    function _tMarked(address a) private view returns (bool r) {
        assembly {
            r := tload(a)
        }
    }
}
