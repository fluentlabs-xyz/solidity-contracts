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

    /// @notice Fallback sink for the non-reporter remainder of an equivocation seizure, used when
    ///         no damage-coverage fund is configured (`ChainConfig.getSlashFundAddress()` unset). A
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

        // A GENESIS validator's key activates from selection epoch 0 so
        // getValidatorsWithKeysAt(0) is populated for the bootstrap committee[0]. The
        // genesis marker is the validator's OWN already-committed membership — seeded
        // `sinceEpoch=0` (visible from epoch 0) via `initialize` — NOT `block.number`
        // vs `dposActivationBlock`: the bare->DPoS migration calls setConsensusKeys at
        // RUNTIME after finalizing PAST the activation block (block.number >=
        // activation), so a block-based discriminator wrongly warms genesis keys to +1
        // and starves committee[0] (v45/v46 boot halt). Reading the membership stamp
        // makes this a pure function of committed state, independent of the
        // setConsensusKeys call site/block. A genuine RUNTIME validator (registered
        // post-genesis, membership visible only from >= 1) keeps the +1 key warmup.
        uint64 activationEpoch =
            StakingLayout.selectionVisibleAt(StakingLayout.stakingStorage(), validatorAddress, 0) ? 0 : _nextEpoch(cfg);
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

        // Tombstone before any state-changing penalty. This ordering is CEI (reentrancy)
        // hygiene only; the tombstone's DURABILITY against a same-tx revert is guaranteed
        // separately by `_seizeSelfStake` never reverting on the reporter payment — CEI
        // ordering alone would NOT stop a failed reporter transfer from rolling it back.
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
        // Selection exit follows the UNIFORM +1 rule (no immediate-exclusion exception,
        // no live tombstone check in the keyed filter — that would reintroduce mid-epoch
        // selection nondeterminism). CONSEQUENCE (accepted, ≤f model): a caught
        // equivocator may still be seated in the ONE committee whose selection was already
        // in flight (selectionEpoch == this epoch); it is slashed + tombstoned + never
        // returns, and we deliberately build no >f defense.
        StakingLayout.setSelectionVisible($, validatorAddress, false, _currentEpoch(cfg));

        _seizeSelfStake(cfg, token, validatorAddress, v.ownerAddress);

        emit IStakingEvents.ValidatorJailed(validatorAddress, _currentEpoch(cfg));
    }

    /// @dev Seize 100% of the offender's OWN bonded self-stake (owner→self delegation): the
    ///      reporter (`msg.sender`) gets `getSlashReporterRewardBps()` (default 30%); the remainder
    ///      goes to the governance-set damage-coverage fund (`getSlashFundAddress()`), or is burned
    ///      when that fund is unset (genesis default). Because only the operator's own stake is
    ///      taken, a self-reporting offender always nets negative (loses 100%, recovers ≤ the
    ///      reporter cut), so no self-report guard is required.
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

        // Interactions: split the seized amount into a governance-set reporter cut and a
        // remainder. The reporter leg is made NON-REVERTING so a bad reporter address
        // can never roll back the tombstone/jail/active-list removal applied above (the whole
        // slash is one atomic tx). For the current plain-ERC20 token the only revert vector is
        // `msg.sender == address(0)` (OZ `ERC20InvalidReceiver`), so an address(0) guard
        // suffices: an invalid reporter simply forfeits its cut into the remainder.
        // NOTE: under the planned native-token migration this reporter leg becomes a native
        // `call{value:}` that can ALSO revert for a contract reporter — it must THEN switch to
        // a failure-tolerant low-level call (success-check → fold the cut into the remainder on
        // failure), not just this address(0) guard.
        uint256 reporterReward = (seized * cfg.getSlashReporterRewardBps()) / 10_000;
        uint256 remainder = seized - reporterReward;
        if (reporterReward > 0 && msg.sender != address(0)) {
            token.safeTransfer(msg.sender, reporterReward);
        } else {
            remainder += reporterReward; // no valid reporter → its cut joins the remainder, never revert the slash
            reporterReward = 0;
        }
        // The non-reporter remainder funds the governance-set damage-coverage account when one is
        // configured; otherwise it is burned to the dead address (genesis default). Like the
        // reporter leg this is a plain-address `safeTransfer`, so for the current plain-ERC20 token
        // it cannot revert the atomic slash — governance is trusted not to point the fund at a
        // token-reverting address. (Under the native-token migration this leg gains the same
        // failure-tolerant `call{value:}` consideration noted for the reporter leg above.)
        address fund = cfg.getSlashFundAddress();
        address recipient = fund == address(0) ? EQUIVOCATION_BURN_SINK : fund;
        if (remainder > 0) token.safeTransfer(recipient, remainder);

        emit IStakingEvents.EquivocationStakeSeized(validatorAddress, msg.sender, reporterReward, remainder, recipient);
    }

    /// @dev True iff the just-stored `committee[target]` differs from the incumbent
    ///      `committee[target-1]`. Both are stored canonically ascending by `peerPubkey`,
    ///      so a set difference always shows as a length or positional mismatch. `target`
    ///      < 1 has no incumbent ⇒ false (genesis is handled consensus-side as a bootstrap
    ///      mint). Drives the deterministic `dkgQual` mint bit set in commitEpochCommittee
    ///      — set ⇔ a genuine membership change re-minted a fresh beacon key at `target`,
    ///      which is what the node-side beacon-key carry-forward arbitration reads.
    function _committeeChangedFromIncumbent(StakingLayout.EpochCommitteeStorage storage $ec, uint64 target)
        private
        view
        returns (bool)
    {
        if (target < 1) return false;
        address[] storage curCommittee = $ec.committee[target];
        address[] storage inc = $ec.committee[target - 1];
        uint256 n = curCommittee.length;
        if (n != inc.length) return true;
        for (uint256 i = 0; i < n; i++) {
            if (curCommittee[i] != inc[i]) return true;
        }
        return false;
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

        // 2-epoch warm-up: the committee is committed a full epoch before its DKG runs
        // (in target-1), so there is no qualify-before-commit deferral — the candidate is
        // always verified+stored unconditionally here. The former v40 incumbent-carry
        // fallback (re-commit committee[target-1] when unqualified) is removed under the
        // <f operating model, in which a frozen committee always completes its DKG; the
        // >=f-breach recovery is a separate, deliberately-deferred concern.

        // Verify the submitted `committee` against the FRESH keyed top-k set AS OF
        // `selectionEpoch`, strictly ascending by peerPubkey. This is now DETERMINISTIC
        // (no stash needed): the selection view (getValidatorsAt) is a pure function of
        // `selectionEpoch` — status transitions take effect at T+1 and keys gate on
        // activationEpoch — so the on-chain re-derivation cannot drift from the
        // off-chain candidate within the commit window.
        address[] memory top = StakingLayout.getValidatorsAt(cfg, selectionEpoch);
        uint256 m = 0;
        for (uint256 i = 0; i < top.length; i++) {
            // A key counts for `selectionEpoch` only once ACTIVE (activationEpoch <=
            // selectionEpoch). A key registered mid-epoch E stamps activationEpoch = E+1
            // (setConsensusKeys, one-shot), so it is invisible to selection for any
            // committee minted from EffBal(E) — the membership analogue of the stake
            // warmup, keeping off-chain derivation and on-chain verify deterministic.
            IStaking.ConsensusKeys storage ck = $ck.consensusKeys[top[i]];
            if (ck.peerPubkey != bytes32(0) && ck.activationEpoch <= selectionEpoch) {
                _tMark(top[i]);
                m++;
            }
        }

        if (committee.length != m) revert IStakingContextErrors.CommitteeLengthMismatch(m, committee.length);
        address[] storage stored = $ec.committee[target];
        bytes32 prev = bytes32(0);
        for (uint256 i = 0; i < committee.length; i++) {
            address v = committee[i];
            IStaking.ConsensusKeys storage ckv = $ck.consensusKeys[v];
            bytes32 peer = ckv.peerPubkey;
            // Keyless OR not-yet-active-for-`selectionEpoch` ⇒ ineligible (same gate as the mark loop).
            if (peer == bytes32(0) || ckv.activationEpoch > selectionEpoch) {
                revert IStakingContextErrors.CommitteeMemberKeyless(v);
            }
            if (!_tMarked(v)) revert IStakingContextErrors.CommitteeMemberNotInActiveSet(v);
            if (peer <= prev) revert IStakingContextErrors.CommitteeNotStrictlyAscending(v);
            _tUnmark(v); // consume → a duplicate address fails _tMarked next time
            prev = peer;
            stored.push(v);
        }

        // Deterministic committee-MINT bit (replaces the permissionless recordDkgQual
        // marker): set iff this committee differs from the incumbent committee[target-1]
        // — a genuine membership change that re-mints a fresh beacon key in target-1's
        // DKG. A no-change epoch leaves it false, so the consensus beacon::carry arbiter
        // carries the previous key. Under the <f model "committee changed" == "DKG will
        // qualify". Genesis (target < 1, no incumbent) leaves it false; the consensus
        // side special-cases the bootstrap mint epoch.
        $ec.dkgQual[target] = _committeeChangedFromIncumbent($ec, target);

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
