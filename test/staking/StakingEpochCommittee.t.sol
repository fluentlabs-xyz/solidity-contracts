// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ChainConfig} from "../../contracts/staking/ChainConfig.sol";
import {Staking} from "../../contracts/staking/Staking.sol";
import {SYSTEM_CALLER} from "../../contracts/staking/StakingContext.sol";
import {BLS12381Verifier} from "../../contracts/libraries/BLS12381Verifier.sol";
import {StakingPool} from "../../contracts/staking/StakingPool.sol";
import {SystemReward} from "../../contracts/staking/SystemReward.sol";
import {MockBlendToken} from "../../contracts/staking/mocks/MockBlendToken.sol";
import {IChainConfig} from "../../contracts/staking/interfaces/IChainConfig.sol";
import {IFluentGovernance} from "../../contracts/staking/interfaces/IFluentGovernance.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {IStakingPool} from "../../contracts/staking/interfaces/IStakingPool.sol";
import {ISystemReward} from "../../contracts/staking/interfaces/ISystemReward.sol";

/// @title Epoch committee freeze + signer-index resolution tests
/// @notice Covers `commitEpochCommittee` (submit + verify) / `resolveSigner` /
///         `getEpochCommittee`.
contract StakingEpochCommitteeTest is Test {
    uint256 internal constant ONE = 1 ether;
    uint32 internal constant EPOCH_INTERVAL = 10; // ChainConfig.epochBlockInterval below
    uint32 internal constant ACTIVE_LEN = 51; // ChainConfig.activeValidatorsLength below (== MAX_ACTIVE_VALIDATORS cap)
    uint64 internal constant RETENTION_MARGIN = 8; // Staking.EPOCH_COMMITTEE_RETENTION_MARGIN
    uint64 internal constant UNDELEGATE_PERIOD = 7; // ChainConfig.undelegatePeriod below
    // retention window = UNDELEGATE_PERIOD + RETENTION_MARGIN.

    Staking internal staking;
    StakingPool internal stakingPool;
    ChainConfig internal chainConfig;
    SystemReward internal systemReward;
    MockBlendToken internal blend;

    address internal sequencer = makeAddr("sequencer");

    event EpochCommitteeCommitted(uint64 indexed epoch, address[] committee);

    // Committed PoP vector (chain_id 20994) — hand-mirrored from
    // `crates/bls/tests/hash_to_g1_conformance.rs` (`verify_pop_valid`) via
    // `test/bls/BlsHashToG1Conformance.t.sol`. PoP has NO address binding ⇒
    // this single tuple is a valid registration for ANY validator address;
    // these tests only care about committee ordering, not the BLS key.
    bytes internal constant PK_REF =
        hex"92b050b6fbe80695b5d56835e978918e37c8707a7fad09a01ae782d4c3170c9baa4c2c196b36eac6b78ceb210b287aeb0727ef1c60e48042142f7bcc8b6382305cd50c5a4542c44ec72a4de6640c194f8ef36bea1dbed168ab6fd8681d910d55";
    bytes internal constant PK_UNC =
        hex"000000000000000000000000000000000727ef1c60e48042142f7bcc8b6382305cd50c5a4542c44ec72a4de6640c194f8ef36bea1dbed168ab6fd8681d910d550000000000000000000000000000000012b050b6fbe80695b5d56835e978918e37c8707a7fad09a01ae782d4c3170c9baa4c2c196b36eac6b78ceb210b287aeb000000000000000000000000000000000f9da5ef5089f62dc55ec91c2459f6ed3fd9981f8d4926ad90dca0314603ae4af86c8fa12bdd2569867f05a24908b7fc0000000000000000000000000000000009ac1ba2c6341d99ba0d6bfab8ea6a3a58726e787ab22b899cd95acfec350c1fc09f5fcbbef992106b61e45eb9158354";
    bytes internal constant SIG_REF_VALID =
        hex"a27ecd57f1889127d81b2a3c46e1905c419302192ebc90f818c7d272b38a6495337f7dde0733d0d431fc1338e8caf62e";
    bytes internal constant SIG_UNC_VALID =
        hex"00000000000000000000000000000000027ecd57f1889127d81b2a3c46e1905c419302192ebc90f818c7d272b38a6495337f7dde0733d0d431fc1338e8caf62e00000000000000000000000000000000109a4722abb94b2ffb8685abe75b4fc8336d2f6534b64fee49baa07ab7357de65036fb93ee119860768cc65daa4c7b1e";

    /// @dev Conformance corpus mirror of crates/bls/tests/ed25519_ordering_conformance.rs;
    ///      regenerate both together.
    function _corpus() internal pure returns (bytes32[10] memory p) {
        p[0] = 0x478243aed376da313d7cf3a60637c264cb36acc936efb341ff8d3d712092d244;
        p[1] = 0xc5bbbb60e412879bbec7bb769804fa8e36e68af10d5477280b63deeaca931bed;
        p[2] = 0x00d21610e478bc59b0c1e70505874e191bf94ab73cb1f9246f963f9bc0a1b253;
        p[3] = 0xff87a0b0a3c7c0ce827e9cada5ff79e75a44a0633bfcb5b50f99307ddb26b337;
        p[4] = 0xe2e8aa145e1ec5cb01ebfaa40e10e12f0230c832fd8135470c001cb86d77de00;
        p[5] = 0x9ab068880fcc795c1ac317b9b5acff698a04b2f9fba6eea41f013dc9942fd8e2;
        p[6] = 0x191fc38f134aaf1b7fdb1f86330b9d03e94bd4ba884f490389de964448e89b3f;
        p[7] = 0x17888c2ca502371245e5e35d5bcf35246c3bc36878e859938c9ead3c54db174f;
        p[8] = 0x4f44e6c7bdfed3d9f48d86149ee3d29382cae8c83ca253e06a70be54a301828b;
        p[9] = 0xee1aa49a4459dfe813a3cf6eb882041230c7b2558469de81f87c9bf23bf10a03;
    }
    // Simplex committee order (= ascending byte lex), indices into _corpus():

    function _expectedSorted() internal pure returns (uint8[10] memory e) {
        e[0] = 2;
        e[1] = 7;
        e[2] = 6;
        e[3] = 0;
        e[4] = 8;
        e[5] = 5;
        e[6] = 1;
        e[7] = 4;
        e[8] = 9;
        e[9] = 3;
    }

    function setUp() public {
        blend = new MockBlendToken();

        uint64 nonce = vm.getNonce(address(this));
        IStaking predictedStaking = IStaking(vm.computeCreateAddress(address(this), nonce + 1));
        ISystemReward predictedSystemReward = ISystemReward(vm.computeCreateAddress(address(this), nonce + 3));
        IStakingPool predictedStakingPool = IStakingPool(vm.computeCreateAddress(address(this), nonce + 5));
        IChainConfig predictedChainConfig = IChainConfig(vm.computeCreateAddress(address(this), nonce + 7));
        IFluentGovernance governance = IFluentGovernance(address(this));

        Staking stakingImpl = new Staking(
            predictedStaking,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig,
            blend,
            address(0),
            address(0)
        );
        staking = Staking(
            payable(
                address(
                    new ERC1967Proxy(
                        address(stakingImpl),
                        abi.encodeCall(Staking.initialize, (address(this), new address[](0), new uint256[](0), uint16(0)))
                    )
                )
            )
        );

        SystemReward systemRewardImpl = new SystemReward(
            predictedStaking,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig,
            blend
        );
        systemReward = SystemReward(
            payable(
                address(
                    new ERC1967Proxy(
                        address(systemRewardImpl),
                        abi.encodeCall(SystemReward.initialize, (address(this), _singleton(address(this)), _singleton16(10_000)))
                    )
                )
            )
        );

        StakingPool stakingPoolImpl = new StakingPool(
            predictedStaking,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig,
            blend
        );
        stakingPool = StakingPool(
            payable(
                address(new ERC1967Proxy(address(stakingPoolImpl), abi.encodeCall(StakingPool.initialize, (address(this)))))
            )
        );

        ChainConfig chainConfigImpl = new ChainConfig(
            predictedStaking,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig,
            blend
        );
        chainConfig = ChainConfig(
            address(
                new ERC1967Proxy(
                    address(chainConfigImpl),
                    abi.encodeCall(
                        ChainConfig.initialize,
                        (
                            address(this),
                            ACTIVE_LEN,
                            EPOCH_INTERVAL,
                            uint32(150),
                            uint32(7),
                            uint32(7), // undelegatePeriod
                            uint256(ONE),
                            uint256(ONE),
                            uint64(0),
                            address(0),
                            address(0),
                            uint256(0)
                        )
                    )
                )
            )
        );

        assertEq(address(staking), address(predictedStaking));
        assertEq(address(chainConfig), address(predictedChainConfig));

        // On-chain PoP wiring: govern-register the verifier and pin
        // block.chainid to the corpus chain (20994) so the committed PoP
        // vector verifies in setConsensusKeys.
        chainConfig.setBlsVerifier(address(new BLS12381Verifier()));
        vm.chainId(20994);

        vm.coinbase(sequencer);
    }


    // NOTE: validators registered (+ keyed) at epoch 0 are selection-eligible only
    // from selectionEpoch 1 (stamp `sinceEpoch`/`activationEpoch` = nextEpoch = 1 —
    // the committee warmup mirroring the stake warmup). Under the 2-epoch warm-up
    // committee[N] is selected from EffBal(N-2), so the FIRST committee that can
    // contain them is committee[3] (selectionEpoch = 3-2 = 1).
    function test_commitEpochCommittee_acceptsCanonicalOrder() public {
        address a = _validator("A", bytes32(uint256(0x30)));
        address b = _validator("B", bytes32(uint256(0x10)));
        address c = _validator("C", bytes32(uint256(0x20)));

        _rollToEpoch(3);
        _commit();

        address[] memory got = staking.getEpochCommittee(3);
        assertEq(got.length, 3);
        assertEq(got[0], b); // 0x10
        assertEq(got[1], c); // 0x20
        assertEq(got[2], a); // 0x30
    }

    function test_commitEpochCommittee_excludesKeylessValidators() public {
        address a = _validator("A", bytes32(uint256(0x10)));
        staking.addValidator(makeAddr("keyless")); // no consensus keys
        address c = _validator("C", bytes32(uint256(0x20)));

        _rollToEpoch(3);
        _commit();

        address[] memory got = staking.getEpochCommittee(3);
        assertEq(got.length, 2);
        assertEq(got[0], a);
        assertEq(got[1], c);
    }

    function test_commitEpochCommittee_respectsTopKByStake() public {
        chainConfig.setActiveValidatorsLength(2);
        _validator("A", bytes32(uint256(0x10)));
        _validator("B", bytes32(uint256(0x20)));
        _validator("C", bytes32(uint256(0x30)));

        _rollToEpoch(3);
        _commit();

        assertEq(staking.getEpochCommittee(3).length, 2);
    }

    function test_commitEpochCommittee_idempotentSecondCallSameEpoch() public {
        address a = _validator("A", bytes32(uint256(0x10)));
        _rollToEpoch(3);
        _commit();
        _commit(); // no-op

        address[] memory got = staking.getEpochCommittee(3);
        assertEq(got.length, 1);
        assertEq(got[0], a);
    }

    function test_commitEpochCommittee_idempotentEvenWhenCommitteeEmpty() public {
        // no keyed validators ⇒ m == 0, committee stays empty but epoch is
        // recorded; a re-call must still be a no-op (sentinel guard).
        staking.addValidator(makeAddr("keylessOnly"));
        _rollToEpoch(1);
        _commit(); // submits empty array
        _commit(); // must be a clean no-op, not a recompute/re-emit

        assertEq(staking.getEpochCommittee(1).length, 0);
    }

    function test_commitEpochCommittee_emitsEpochCommitteeCommitted() public {
        address a = _validator("A", bytes32(uint256(0x10)));
        address b = _validator("B", bytes32(uint256(0x20)));
        _rollToEpoch(3);
        // Catch up committees 0,1,2 so the next commit targets epoch 3.
        while (staking.nextEpochToCommit() < 3) {
            uint64 t = staking.nextEpochToCommit();
            address[] memory cc = _canonicalAt(t < 2 ? 0 : t - 2);
            vm.prank(SYSTEM_CALLER);
            staking.commitEpochCommittee(cc);
        }

        address[] memory expected = new address[](2);
        expected[0] = a;
        expected[1] = b;
        vm.expectEmit(true, false, false, true, address(staking));
        emit EpochCommitteeCommitted(3, expected);
        vm.prank(SYSTEM_CALLER);
        staking.commitEpochCommittee(expected);
    }

    function test_commitEpochCommittee_prunesEpochBeyondRetention() public {
        _validator("A", bytes32(uint256(0x10)));
        uint64 window = UNDELEGATE_PERIOD + RETENTION_MARGIN;

        _rollToEpoch(3);
        _commit();
        assertEq(staking.getEpochCommittee(3).length, 1);

        uint64 far = 3 + window + 1;
        _rollToEpoch(far);
        _commit();

        assertEq(staking.getEpochCommittee(3).length, 0, "stale epoch must be pruned");
        assertEq(staking.getEpochCommittee(far).length, 1, "current epoch retained");
    }

    function test_commitEpochCommittee_pruneCursorDoesNotLeakAcrossSkippedCommits() public {
        _validator("A", bytes32(uint256(0x10)));
        // commit epoch 3 (first non-empty committee), then jump far ahead skipping every
        // epoch in between; the cursor must still reclaim epoch 3's storage.
        _rollToEpoch(3);
        _commit();
        _rollToEpoch(3 + UNDELEGATE_PERIOD + RETENTION_MARGIN + 5);
        _commit();
        assertEq(staking.getEpochCommittee(3).length, 0, "skipped-commit window must not leak");
    }

    function test_commitEpochCommittee_doesNotRewritePastEpoch() public {
        _validator("A", bytes32(uint256(0x10)));
        _rollToEpoch(5);
        _commit(); // commits committees 0..5

        // Past epochs are immutable: commitEpochCommittee only ever targets the
        // next-uncommitted epoch (lastCommittedEpochP1), never a committed one.
        assertEq(staking.nextEpochToCommit(), 6, "cursor advanced past all committed epochs");
        address[] memory at3 = staking.getEpochCommittee(3);
        assertEq(at3.length, 1);

        _rollToEpoch(7);
        _commit(); // commits 6,7 — must not touch epoch 3

        address[] memory still3 = staking.getEpochCommittee(3);
        assertEq(still3.length, at3.length, "past epoch must not be rewritten");
        assertEq(still3[0], at3[0]);
        assertEq(staking.getEpochCommittee(5).length, 1);
    }

    function test_RevertIf_commitEpochCommittee_nonSystemCaller() public {
        _validator("A", bytes32(uint256(0x10)));
        _rollToEpoch(1);
        uint64 t = staking.nextEpochToCommit();
        address[] memory c = _canonicalAt(t < 2 ? 0 : t - 2);
        vm.prank(makeAddr("notSystem"));
        vm.expectRevert(abi.encodeWithSignature("OnlySystemCall()"));
        staking.commitEpochCommittee(c);
    }

    function test_RevertIf_commitEpochCommittee_wrongOrder() public {
        address a = _validator("A", bytes32(uint256(0x10)));
        address b = _validator("B", bytes32(uint256(0x20)));
        _rollToEpoch(3);
        _catchUpUntil(3); // target the first epoch (3) the validators are selection-eligible

        address[] memory bad = new address[](2);
        bad[0] = b; // 0x20 first — not strictly ascending
        bad[1] = a;
        vm.prank(SYSTEM_CALLER);
        vm.expectRevert(abi.encodeWithSignature("CommitteeNotStrictlyAscending(address)", a));
        staking.commitEpochCommittee(bad);
    }

    function test_RevertIf_commitEpochCommittee_lengthMismatch() public {
        address a = _validator("A", bytes32(uint256(0x10)));
        _validator("B", bytes32(uint256(0x20)));
        _rollToEpoch(3);
        _catchUpUntil(3);

        address[] memory bad = new address[](1);
        bad[0] = a; // only 1 of 2 keyed members
        vm.prank(SYSTEM_CALLER);
        vm.expectRevert(abi.encodeWithSignature("CommitteeLengthMismatch(uint256,uint256)", uint256(2), uint256(1)));
        staking.commitEpochCommittee(bad);
    }

    function test_RevertIf_commitEpochCommittee_keylessMember() public {
        _validator("A", bytes32(uint256(0x10)));
        address b = _validator("B", bytes32(uint256(0x20)));
        address keyless = makeAddr("keyless");
        staking.addValidator(keyless);
        _rollToEpoch(3);
        _catchUpUntil(3);

        // length == m (=2) but swaps a real keyed member for the keyless one.
        address[] memory bad = new address[](2);
        bad[0] = keyless;
        bad[1] = b;
        vm.prank(SYSTEM_CALLER);
        vm.expectRevert(abi.encodeWithSignature("CommitteeMemberKeyless(address)", keyless));
        staking.commitEpochCommittee(bad);
    }

    function test_RevertIf_commitEpochCommittee_nonMember() public {
        address a = _validator("A", bytes32(uint256(0x10)));
        _validator("B", bytes32(uint256(0x20)));
        // An outsider that is keyed but NOT in the active staking set.
        address outsider = makeAddr("outsider");
        staking.addValidator(outsider);
        vm.prank(outsider);
        staking.setConsensusKeys(outsider, PK_UNC, SIG_UNC_VALID, bytes32(uint256(0x05)));
        chainConfig.setActiveValidatorsLength(2); // top-k excludes the 3rd by stake-equal cutoff
        _rollToEpoch(3);
        _catchUpUntil(3);

        // length matches m(=2) but swaps a real member for the outsider
        address[] memory bad = new address[](2);
        bad[0] = outsider; // 0x05
        bad[1] = a; // 0x10
        vm.prank(SYSTEM_CALLER);
        // outsider is keyed, so it passes the keyless check but fails set membership
        vm.expectRevert(abi.encodeWithSignature("CommitteeMemberNotInActiveSet(address)", outsider));
        staking.commitEpochCommittee(bad);
    }


    function test_resolveSigner_returnsValidatorAtSortedIndex() public {
        address a = _validator("A", bytes32(uint256(0x30)));
        address b = _validator("B", bytes32(uint256(0x10)));
        address c = _validator("C", bytes32(uint256(0x20)));
        _rollToEpoch(3);
        _commit();

        assertEq(staking.resolveSigner(3, 0), b);
        assertEq(staking.resolveSigner(3, 1), c);
        assertEq(staking.resolveSigner(3, 2), a);
    }

    function test_resolveSigner_matchesSimplexConformanceVectors() public {
        bytes32[10] memory corpus = _corpus();
        uint8[10] memory expected = _expectedSorted();

        address[10] memory v;
        for (uint256 i = 0; i < 10; i++) {
            v[i] = _validator(string.concat("conf", vm.toString(i)), corpus[i]);
        }

        _rollToEpoch(4);
        _commit(); // _canonicalAt() reproduces the Simplex committee order

        address[] memory committee = staking.getEpochCommittee(4);
        assertEq(committee.length, 10);
        for (uint256 pos = 0; pos < 10; pos++) {
            assertEq(committee[pos], v[expected[pos]], "ordering diverged from Simplex committee corpus");
            assertEq(
                staking.getConsensusKeys(committee[pos]).peerPubkey,
                corpus[expected[pos]],
                "peerPubkey/index mismatch vs Simplex committee corpus"
            );
            assertEq(staking.resolveSigner(4, uint32(pos)), v[expected[pos]]);
        }
    }

    function test_RevertIf_commitEpochCommittee_seedOrderRejected() public {
        // Submitting the corpus in (unsorted) SEED order must be rejected —
        // the contract enforces the unique canonical order.
        bytes32[10] memory corpus = _corpus();
        address[] memory seedOrder = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            seedOrder[i] = _validator(string.concat("seed", vm.toString(i)), corpus[i]);
        }
        // committee[3] (selEpoch 1) is the first with all 10 validators keyed-for-selection,
        // so the ordering check (not a length mismatch) fires on the unsorted submission.
        _rollToEpoch(3);
        _catchUpUntil(3);
        vm.prank(SYSTEM_CALLER);
        vm.expectRevert(); // CommitteeNotStrictlyAscending at the first descending pair
        staking.commitEpochCommittee(seedOrder);
    }

    function test_resolveSigner_pastEpochUnaffectedByLaterStakeDrift() public {
        address a = _validator("A", bytes32(uint256(0x30)));
        address b = _validator("B", bytes32(uint256(0x10)));
        address c = _validator("C", bytes32(uint256(0x20)));
        _rollToEpoch(3);
        _commit();
        address[] memory snapshot = staking.getEpochCommittee(3);

        _validator("D", bytes32(uint256(0x05))); // added epoch 3 → eligible selEpoch 4 → committee[6]
        _validator("E", bytes32(uint256(0x40)));
        _rollToEpoch(6);
        _commit();

        address[] memory still = staking.getEpochCommittee(3);
        assertEq(still.length, snapshot.length);
        for (uint256 i = 0; i < snapshot.length; i++) {
            assertEq(still[i], snapshot[i]);
        }
        assertEq(staking.resolveSigner(3, 0), b);
        assertEq(staking.resolveSigner(3, 1), c);
        assertEq(staking.resolveSigner(3, 2), a);
        // committee[6] (selEpoch 4) is the first to see D,E → all 5.
        assertEq(staking.getEpochCommittee(6).length, 5);
    }

    function test_resolveSigner_pastEpochUnaffectedByLaterKChange() public {
        address a = _validator("A", bytes32(uint256(0x30)));
        address b = _validator("B", bytes32(uint256(0x10)));
        address c = _validator("C", bytes32(uint256(0x20)));
        _rollToEpoch(3);
        _commit();
        assertEq(staking.getEpochCommittee(3).length, 3);

        chainConfig.setActiveValidatorsLength(1);
        _rollToEpoch(4);
        _commit();

        assertEq(staking.resolveSigner(3, 0), b);
        assertEq(staking.resolveSigner(3, 1), c);
        assertEq(staking.resolveSigner(3, 2), a);
        assertEq(staking.getEpochCommittee(3).length, 3);
        assertEq(staking.getEpochCommittee(4).length, 1);
    }

    function test_RevertIf_resolveSigner_indexOutOfRange() public {
        _validator("A", bytes32(uint256(0x10)));
        _rollToEpoch(3); // committee[3] is the first with a selection-eligible A
        _commit();
        vm.expectRevert(
            abi.encodeWithSignature("SignerIndexOutOfRange(uint64,uint32,uint256)", uint64(3), uint32(5), uint256(1))
        );
        staking.resolveSigner(3, 5);
    }

    function test_RevertIf_resolveSigner_epochNotCommitted() public {
        vm.expectRevert(abi.encodeWithSignature("EpochCommitteeNotCommitted(uint64)", uint64(9)));
        staking.resolveSigner(9, 0);
    }

    function test_getEpochCommittee_emptyForUncommittedEpoch() public view {
        assertEq(staking.getEpochCommittee(42).length, 0);
    }

    function test_getEpochCommitteeWithStakes_joinsCommitteeKeysAndStakes() public {
        address a = _validator("A", bytes32(uint256(0x10)));
        address b = _validator("B", bytes32(uint256(0x20)));
        uint256 stakeA = 3 * ONE;
        uint256 stakeB = 5 * ONE;
        // Delegated at epoch 0 ⇒ effective at epoch 2 (WARMUP_DELAY), changedAt==2.
        _delegate(a, stakeA);
        _delegate(b, stakeB);

        _rollToEpoch(3);
        _commit();

        (address[] memory addrs, IStaking.ConsensusKeys[] memory keys, uint256[] memory stakes) =
            staking.getEpochCommitteeWithStakes(3);

        address[] memory committee = staking.getEpochCommittee(3);
        assertEq(addrs.length, committee.length, "addrs length mismatch");
        assertEq(keys.length, addrs.length, "keys length mismatch");
        assertEq(stakes.length, addrs.length, "stakes length mismatch");

        // committee order is ascending peerPubkey ⇒ [a (0x10), b (0x20)].
        assertEq(addrs[0], a, "addrs[0]");
        assertEq(addrs[1], b, "addrs[1]");
        assertEq(keys[0].peerPubkey, bytes32(uint256(0x10)), "keys[0].peerPubkey");
        assertEq(keys[1].peerPubkey, bytes32(uint256(0x20)), "keys[1].peerPubkey");
        assertEq(stakes[0], stakeA, "stakes[0] (wei)");
        assertEq(stakes[1], stakeB, "stakes[1] (wei)");
    }

    function test_getEpochCommitteeWithStakes_emptyForUncommittedEpoch() public view {
        (address[] memory addrs, IStaking.ConsensusKeys[] memory keys, uint256[] memory stakes) =
            staking.getEpochCommitteeWithStakes(42);
        assertEq(addrs.length, 0, "addrs");
        assertEq(keys.length, 0, "keys");
        assertEq(stakes.length, 0, "stakes");
    }

    /// Regression for D3: the getter reports the at-or-before-`epoch` snapshot
    /// (`totalDelegatedToValidatorAt` → `validatorSnapshotAtOrBefore`), NOT the
    /// validator's latest `changedAt` snapshot when its stake last changed AFTER
    /// `epoch` (`changedAt > epoch`). A future-leaking weight would split leader
    /// election across nodes.
    function test_getEpochCommitteeWithStakes_usesAtOrBeforeEpochStake() public {
        address v = _validator("V", bytes32(uint256(0x10)));
        uint256 first = 2 * ONE; // delegated at epoch 0 ⇒ slot[2], changedAt==2
        uint256 second = 4 * ONE; // delegated at epoch 3 ⇒ slot[5], changedAt==5
        _delegate(v, first);
        _rollToEpoch(3);
        _delegate(v, second);

        _rollToEpoch(4);
        _commit(); // committee[4] is selected from EffBal(2); V is in it (visible from selEpoch 1).

        (,, uint256[] memory stakes) = staking.getEpochCommitteeWithStakes(4);
        assertEq(stakes.length, 1, "committee size");
        // epoch 4 sits between slot[2] and slot[5]: the at-or-before value is `first`.
        assertEq(stakes[0], first, "getter must report at-or-before-epoch stake");
    }


    function test_commitEpochCommittee_storageIsolatedFromOtherNamespaces() public {
        address a = _validator("A", bytes32(uint256(0x10)));
        (address ownerBefore, uint8 statusBefore,,,,,,) = staking.getValidatorStatus(a);

        _rollToEpoch(1);
        _commit();

        (address ownerAfter, uint8 statusAfter,,,,,,) = staking.getValidatorStatus(a);
        assertEq(ownerBefore, ownerAfter);
        assertEq(statusBefore, statusAfter);
        assertEq(staking.getConsensusKeys(a).peerPubkey, bytes32(uint256(0x10)));
    }


    function testFuzz_commitEpochCommittee_sortIsTotalOrder(uint256 seed) public {
        uint256 n = 8;
        for (uint256 i = 0; i < n; i++) {
            bytes32 peer = keccak256(abi.encode(seed, i));
            if (peer == bytes32(0)) peer = bytes32(uint256(1));
            _validator(string.concat("fz", vm.toString(i)), peer);
        }
        _rollToEpoch(3);
        _commit();

        address[] memory got = staking.getEpochCommittee(3);
        assertEq(got.length, n);
        for (uint256 i = 1; i < got.length; i++) {
            assertTrue(
                staking.getConsensusKeys(got[i - 1]).peerPubkey < staking.getConsensusKeys(got[i]).peerPubkey,
                "committee not strictly ascending by peerPubkey"
            );
        }
    }

    function test_commitEpochCommittee_scale51Validators() public {
        for (uint256 i = 0; i < 51; i++) {
            _validator(string.concat("s", vm.toString(i)), keccak256(abi.encode("scale", i)));
        }
        _rollToEpoch(3);
        _commit();

        address[] memory got = staking.getEpochCommittee(3);
        assertEq(got.length, 51);
        for (uint256 i = 1; i < got.length; i++) {
            assertTrue(
                staking.getConsensusKeys(got[i - 1]).peerPubkey < staking.getConsensusKeys(got[i]).peerPubkey,
                "not strictly ascending"
            );
        }
    }


    // --- Committee MINT semantics (no incumbent-carry; deterministic dkgQual bit) ---
    //
    // The v40 deferred qualify-before-commit / incumbent-carry branch is DELETED:
    // commitEpochCommittee now ALWAYS verifies+stores the submitted candidate against
    // the fresh getValidatorsAt(selectionEpoch) set, and sets dkgQual[target]
    // deterministically = (committee[target] != committee[target-1]). The former
    // permissionless recordDkgQual marker is gone. Tests below assert those semantics.
    //
    // DELETED (tested removed behavior, not just re-costumed):
    //  - test_recordDkgQual_setsAndReadsBack / _idempotentRepeat / _permissionlessCaller:
    //    the permissionless recordDkgQual marker no longer exists.
    //  - test_recordDkgQual_frozenAfterCommit: the "late marker is a silent no-op" freeze
    //    tested the marker's write path, which is deleted.
    //  - test_commitEpochCommittee_qualifiedChangeCommitsCandidate: the qualified-vs-
    //    unqualified branch is gone; a change ALWAYS commits the candidate, which is now
    //    covered by test_commitEpochCommittee_changeCommitsCandidateNoCarry below.

    /// A genuine membership CHANGE commits the submitted candidate directly — there is
    /// no incumbent-carry fallback anymore — and deterministically mints the dkgQual bit.
    /// A (epoch 0) is selection-eligible from selEpoch 1 → first appears in committee[3];
    /// B (epoch 1) from selEpoch 2 → the CHANGE first appears in committee[4]'s candidate.
    /// (Rewritten from the deleted test_commitEpochCommittee_unqualifiedChangeCarriesIncumbent.)
    function test_commitEpochCommittee_changeCommitsCandidateNoCarry() public {
        address a = _validator("A", bytes32(uint256(0x10)));
        _rollToEpoch(1);
        address b = _validator("B", bytes32(uint256(0x20)));
        _rollToEpoch(4);
        _catchUpUntil(4); // commits 0..3; committee[3] (selEpoch 1) = {a}
        assertEq(staking.getEpochCommittee(3).length, 1);
        assertEq(staking.getEpochCommittee(3)[0], a);

        // committee[4]: candidate (selEpoch 2) = {a,b} — a genuine change vs committee[3]={a}.
        address[] memory candidate = _canonicalAt(2); // {a, b}
        assertEq(candidate.length, 2, "candidate grew to 2");
        vm.prank(SYSTEM_CALLER);
        staking.commitEpochCommittee(candidate);

        address[] memory got = staking.getEpochCommittee(4);
        assertEq(got.length, 2, "change commits the candidate (no incumbent carry)");
        assertEq(got[0], a);
        assertEq(got[1], b);
        assertTrue(staking.getDkgQual(4), "membership change mints the dkgQual bit");
        assertEq(staking.nextEpochToCommit(), 5, "cursor advances");
    }

    /// A no-change epoch commits the (identical) candidate and leaves the mint bit false.
    /// (Rewritten from the deleted test_commitEpochCommittee_noChangeUnqualifiedCarriesIdenticalSet:
    /// the "carry" wording is gone — it commits the identical candidate directly.)
    function test_commitEpochCommittee_noChangeLeavesBitFalse() public {
        address a = _validator("A", bytes32(uint256(0x10)));
        _rollToEpoch(4);
        _catchUpUntil(4); // commits 0..3; committee[3] (selEpoch 1) = {a}
        assertEq(staking.getEpochCommittee(3).length, 1);

        // committee[4] (selEpoch 2) = {a} — identical to committee[3]={a}.
        address[] memory candidate = _canonicalAt(2); // {a}
        assertEq(candidate.length, 1);
        vm.prank(SYSTEM_CALLER);
        staking.commitEpochCommittee(candidate);

        address[] memory got = staking.getEpochCommittee(4);
        assertEq(got.length, 1, "no-change commits the identical candidate");
        assertEq(got[0], a);
        assertFalse(staking.getDkgQual(4), "identical set leaves the mint bit false");
    }

    // --- Added regression/semantics tests for the committee-commit change ---

    /// Bug-B regression (the exact bug this whole change fixes): a committed committee is
    /// a STORED immutable array; a LATER cap raise must NOT resize it. Commit committee[A]
    /// (A>=2) at cap=k selecting from EffBal(A-2); raise the cap; the stored committee is
    /// still exactly the original k members.
    function test_commitEpochCommittee_committedCommitteeImmutableToLaterCapRaise() public {
        uint32 k = 2;
        chainConfig.setActiveValidatorsLength(k);
        _validator("A", bytes32(uint256(0x10)));
        _validator("B", bytes32(uint256(0x20)));
        _validator("C", bytes32(uint256(0x30))); // 3 keyed validators, cap=k ⇒ committee holds k

        _rollToEpoch(3); // committee[3] (selEpoch 1) is the first eligible one
        _commit();
        address[] memory orig = staking.getEpochCommittee(3);
        assertEq(orig.length, k, "committed committee capped at k");

        // Raise the cap AFTER the commit — the stored array must not grow.
        chainConfig.setActiveValidatorsLength(k + 1);
        (address[] memory addrs,,) = staking.getEpochCommitteeWithStakes(3);
        assertEq(addrs.length, k, "stored committee immutable: a later cap raise cannot resize it");
        for (uint256 i = 0; i < k; i++) {
            assertEq(addrs[i], orig[i], "stored committee membership unchanged");
        }
    }

    /// The dkgQual mint bit is set DETERMINISTICALLY at commit time: TRUE for a CHANGE
    /// epoch (committed set != committee[target-1]), FALSE for a NO-CHANGE epoch.
    function test_commitEpochCommittee_mintBitIsDeterministic() public {
        _validator("A", bytes32(uint256(0x10)));
        _rollToEpoch(1);
        _validator("B", bytes32(uint256(0x20)));
        _rollToEpoch(5);
        _catchUpUntil(4); // commits 0..3; committee[3] (selEpoch 1) = {a}

        // CHANGE: committee[4] (selEpoch 2) = {a,b} != committee[3]={a}.
        address[] memory chg = _canonicalAt(2);
        assertEq(chg.length, 2);
        vm.prank(SYSTEM_CALLER);
        staking.commitEpochCommittee(chg);
        assertTrue(staking.getDkgQual(4), "change epoch mints the bit");

        // NO-CHANGE: committee[5] (selEpoch 3) = {a,b} == committee[4].
        address[] memory same = _canonicalAt(3);
        assertEq(same.length, 2);
        vm.prank(SYSTEM_CALLER);
        staking.commitEpochCommittee(same);
        assertFalse(staking.getDkgQual(5), "no-change epoch leaves the bit false");
    }

    /// The commit gate is `target <= currentEpoch + 2`: a target exactly at cur+2 commits,
    /// a target beyond cur+2 reverts EpochNotYetCommittable.
    function test_commitEpochCommittee_plus2GateBoundary() public {
        _validator("A", bytes32(uint256(0x10)));
        _rollToEpoch(10);
        _catchUpUntil(5); // commit committees 0..4 ⇒ nextEpochToCommit() == 5
        assertEq(staking.nextEpochToCommit(), 5);

        address[] memory cand = _canonicalAt(3); // selectionEpoch for target 5 (= 5-2)

        // target(5) > cur(2)+2 ⇒ reverts.
        _rollToEpoch(2);
        vm.prank(SYSTEM_CALLER);
        vm.expectRevert(abi.encodeWithSignature("EpochNotYetCommittable(uint64,uint64)", uint64(5), uint64(2)));
        staking.commitEpochCommittee(cand);

        // target(5) == cur(3)+2 ⇒ succeeds.
        _rollToEpoch(3);
        vm.prank(SYSTEM_CALLER);
        staking.commitEpochCommittee(cand);
        assertEq(staking.nextEpochToCommit(), 6, "boundary commit succeeded");
        assertEq(staking.getEpochCommittee(5).length, 1);
    }

    // --- Selection-view determinism pins (frozen-input committee eligibility) ---

    /// @dev Count keyed-for-`epoch` members in the selection view (peerPubkey != 0 after
    ///      the activationEpoch key gate zeroes not-yet-active keys).
    function _keyedCountAt(uint64 epoch) internal view returns (uint256 n) {
        (, IStaking.ConsensusKeys[] memory keys) = staking.getValidatorsWithKeysAt(epoch);
        for (uint256 i = 0; i < keys.length; i++) {
            if (keys[i].peerPubkey != bytes32(0)) n++;
        }
    }

    /// @dev Member count of the selection view at `epoch` (the addrs half of the tuple).
    function _selCountAt(uint64 epoch) internal view returns (uint256) {
        (address[] memory addrs,) = staking.getValidatorsWithKeysAt(epoch);
        return addrs.length;
    }

    /// A status EXIT mid-epoch T must NOT change the selection view for any epoch <= T
    /// (the in-flight committee derivation stays frozen); it takes effect exactly at T+1.
    /// disableValidator exercises the same `setSelectionVisible(false, +1)` path as both
    /// jail types, so this pins the whole exit family.
    function test_selectionView_frozenAgainstMidEpochExit() public {
        address a = _validator("A", bytes32(uint256(0x10)));
        _validator("B", bytes32(uint256(0x20)));
        _validator("C", bytes32(uint256(0x30)));
        _rollToEpoch(3);

        (address[] memory before,) = staking.getValidatorsWithKeysAt(2); // frozen since epoch_start(2)
        assertEq(before.length, 3, "selEpoch 2 has all three");

        // Exit A mid-epoch 3.
        staking.disableValidator(a);

        (address[] memory afterExit,) = staking.getValidatorsWithKeysAt(2);
        assertEq(afterExit.length, before.length, "selEpoch 2 view UNCHANGED by an epoch-3 exit");
        for (uint256 i = 0; i < before.length; i++) {
            assertEq(afterExit[i], before[i], "selEpoch 2 order/content frozen");
        }
        // The current selEpoch 3 is also unaffected (exit effect is +1).
        assertEq(_selCountAt(3), 3, "selEpoch 3 still sees A");
        // The exit lands exactly at selEpoch 4.
        (address[] memory at4,) = staking.getValidatorsWithKeysAt(4);
        assertEq(at4.length, 2, "selEpoch 4 excludes the exited A");
        assertTrue(at4[0] != a && at4[1] != a, "A gone from selEpoch 4");
    }

    /// A consensus key registered mid-epoch T (activationEpoch = T+1) is NOT keyed-for-
    /// selection for any committee minted from EffBal(<=T); it becomes keyed at exactly
    /// activationEpoch — the membership analogue of the stake warmup.
    function test_selectionView_keyWarmup_visibleFromActivationEpoch() public {
        _validator("A", bytes32(uint256(0x10))); // baseline: member + key active from selEpoch 1
        // B is an active MEMBER from epoch 0 but registers its key later.
        address b = makeAddr("B");
        staking.addValidator(b);
        _rollToEpoch(3);
        vm.prank(b);
        staking.setConsensusKeys(b, PK_UNC, SIG_UNC_VALID, bytes32(uint256(0x20))); // activationEpoch = 4

        // B is a member at selEpoch 1..3 but KEYLESS-for-selection until activationEpoch 4.
        assertEq(_keyedCountAt(1), 1, "selEpoch 1: only A keyed");
        assertEq(_keyedCountAt(3), 1, "selEpoch 3: B's key not yet active");
        assertEq(_keyedCountAt(4), 2, "selEpoch 4: B key active at activationEpoch");
    }

    /// GENESIS BOOTSTRAP pin (v45/v46 regression). REPRODUCES THE REAL SOAK TIMING:
    /// the bare->DPoS migration waits for the sequencer to finalize PAST the activation
    /// block (lib.sh:401) and only THEN cast-calls setConsensusKeys — i.e. keys are
    /// registered POST-activation (`block.number >= dposActivationBlock`). A block-based
    /// genesis discriminator therefore warms genesis keys to +1 and empties committee[0]
    /// (the boot halt). The membership-based discriminator (validator seeded via
    /// `initialize` with `sinceEpoch=0`, visible from epoch 0) is block-independent and
    /// keeps genesis keys active from selection epoch 0.
    function test_genesisBootstrap_keysActiveFromEpoch0_committee0Commits() public {
        address g1 = makeAddr("g1");
        address g2 = makeAddr("g2");
        address[] memory gvals = new address[](2);
        gvals[0] = g1;
        gvals[1] = g2;
        uint64 activation = 5 * EPOCH_INTERVAL;
        Staking gs = _deployGenesisStaking(gvals, activation);

        // *** Register keys POST-ACTIVATION *** (the real migration timing that broke v46).
        vm.roll(uint256(activation) + 2 * EPOCH_INTERVAL); // well past activation (epoch 2)
        vm.prank(g1);
        gs.setConsensusKeys(g1, PK_UNC, SIG_UNC_VALID, bytes32(uint256(0x10)));
        vm.prank(g2);
        gs.setConsensusKeys(g2, PK_UNC, SIG_UNC_VALID, bytes32(uint256(0x20)));

        // Genesis keys activate from selection epoch 0 despite being registered post-activation.
        assertEq(gs.getConsensusKeys(g1).activationEpoch, 0, "genesis key active from epoch 0 (block-independent)");
        assertEq(gs.getConsensusKeys(g2).activationEpoch, 0);

        // selEpoch 0 selection view is populated WITH non-zeroed keys.
        (address[] memory addrs, IStaking.ConsensusKeys[] memory keys) = gs.getValidatorsWithKeysAt(0);
        assertEq(addrs.length, 2, "genesis members visible at selEpoch 0");
        assertTrue(keys[0].peerPubkey != bytes32(0) && keys[1].peerPubkey != bytes32(0), "genesis keys not gated out");

        // committee[0] commits the genesis set (ascending peerPubkey: g1(0x10), g2(0x20)).
        address[] memory committee = new address[](2);
        committee[0] = g1;
        committee[1] = g2;
        vm.prank(SYSTEM_CALLER);
        gs.commitEpochCommittee(committee);
        assertEq(gs.getEpochCommittee(0).length, 2, "committee[0] populated from genesis bootstrap");

        // Contrast: a genuine RUNTIME validator (registered post-genesis, membership
        // visible only from >= 1) still warms its key up +1.
        address r = makeAddr("runtime");
        gs.addValidator(r); // sinceEpoch = nextEpoch (epoch 3) ⇒ membership NOT visible at epoch 0
        vm.prank(r);
        gs.setConsensusKeys(r, PK_UNC, SIG_UNC_VALID, bytes32(uint256(0x30)));
        assertEq(gs.getConsensusKeys(r).activationEpoch, 3, "runtime key warms up to nextEpoch (+1)");
    }

    /// @dev Deploy a fresh Staking (+ its ChainConfig/SystemReward/StakingPool) seeded
    ///      with genesis validators via `initialize` (sinceEpoch=0) and a FUTURE
    ///      activation block, mirroring the genesis-bootstrap flow. 0-stake genesis
    ///      validators (no token transfer). Verifier wired; chainid already 20994.
    function _deployGenesisStaking(address[] memory gvals, uint64 activationBlock) internal returns (Staking gs) {
        uint256[] memory gstakes = new uint256[](gvals.length);
        uint64 nonce = vm.getNonce(address(this));
        IStaking pStaking = IStaking(vm.computeCreateAddress(address(this), nonce + 1));
        ISystemReward pReward = ISystemReward(vm.computeCreateAddress(address(this), nonce + 3));
        IStakingPool pPool = IStakingPool(vm.computeCreateAddress(address(this), nonce + 5));
        IChainConfig pCfg = IChainConfig(vm.computeCreateAddress(address(this), nonce + 7));
        IFluentGovernance gov = IFluentGovernance(address(this));

        Staking impl = new Staking(pStaking, pReward, pPool, gov, pCfg, blend, address(0), address(0));
        gs = Staking(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl), abi.encodeCall(Staking.initialize, (address(this), gvals, gstakes, uint16(0)))
                    )
                )
            )
        );
        SystemReward rImpl = new SystemReward(pStaking, pReward, pPool, gov, pCfg, blend);
        new ERC1967Proxy(
            address(rImpl),
            abi.encodeCall(SystemReward.initialize, (address(this), _singleton(address(this)), _singleton16(10_000)))
        );
        StakingPool pImpl = new StakingPool(pStaking, pReward, pPool, gov, pCfg, blend);
        new ERC1967Proxy(address(pImpl), abi.encodeCall(StakingPool.initialize, (address(this))));
        ChainConfig cImpl = new ChainConfig(pStaking, pReward, pPool, gov, pCfg, blend);
        ChainConfig gcfg = ChainConfig(
            address(
                new ERC1967Proxy(
                    address(cImpl),
                    abi.encodeCall(
                        ChainConfig.initialize,
                        (
                            address(this),
                            ACTIVE_LEN,
                            EPOCH_INTERVAL,
                            uint32(150),
                            uint32(7),
                            uint32(7),
                            uint256(ONE),
                            uint256(ONE),
                            activationBlock,
                            address(0),
                            address(0),
                            uint256(0)
                        )
                    )
                )
            )
        );
        assertEq(address(gs), address(pStaking));
        assertEq(address(gcfg), address(pCfg));
        gcfg.setBlsVerifier(address(new BLS12381Verifier()));
    }

    /// Governance re-activation (Pending -> Active) enters the selection view at T+1
    /// (mirrors reinstate-from-jail; both use `setSelectionVisible(true, +1)`).
    function test_selectionView_governanceEntryAtPlus1() public {
        _validator("A", bytes32(uint256(0x10)));
        address b = _validator("B", bytes32(uint256(0x20)));
        _rollToEpoch(3);
        staking.disableValidator(b); // exit: B invisible from selEpoch 4
        assertEq(_selCountAt(4), 1, "selEpoch 4: B out");

        _rollToEpoch(5);
        staking.activateValidator(b); // entry: B visible again from selEpoch 6
        assertEq(_selCountAt(5), 1, "selEpoch 5: entry not yet effective");
        assertEq(_selCountAt(6), 2, "selEpoch 6: B re-enters at exactly +1");
    }

    function _validator(string memory label, bytes32 peerPubkey) internal returns (address v) {
        v = makeAddr(label);
        staking.addValidator(v); // governance == address(this); owner == v
        vm.prank(v);
        staking.setConsensusKeys(v, PK_UNC, SIG_UNC_VALID, peerPubkey);
    }

    /// @dev Delegate `amount` BLEND to `validator` from a funded staker. Effective
    ///      at `currentEpoch + WARMUP_DELAY` (snapshot written there, `changedAt`
    ///      advanced to it) — see {StakingLayout.touchValidatorSnapshot}.
    function _delegate(address validator, uint256 amount) internal {
        address staker = makeAddr("committeeStaker");
        blend.mint(staker, amount);
        vm.startPrank(staker);
        blend.approve(address(staking), amount);
        staking.delegate(validator, amount);
        vm.stopPrank();
    }

    /// @dev Reproduces the contract's canonical committee off-chain for a given
    ///      epoch: the keyed subset of getValidatorsWithKeysAt(epoch) top-k,
    ///      sorted ascending by peerPubkey. Parameterized by epoch because the
    ///      ahead-commit model commits committee[target] for target possibly
    ///      below the current epoch.
    function _canonicalAt(uint64 epoch) internal view returns (address[] memory out) {
        (address[] memory top, ) = staking.getValidatorsWithKeysAt(epoch);
        address[] memory keyed = new address[](top.length);
        bytes32[] memory pk = new bytes32[](top.length);
        uint256 m = 0;
        for (uint256 i = 0; i < top.length; i++) {
            bytes32 peer = staking.getConsensusKeys(top[i]).peerPubkey;
            if (peer == bytes32(0)) continue;
            keyed[m] = top[i];
            pk[m] = peer;
            m++;
        }
        for (uint256 i = 1; i < m; i++) {
            address aV = keyed[i];
            bytes32 aK = pk[i];
            uint256 j = i;
            while (j > 0 && pk[j - 1] > aK) {
                keyed[j] = keyed[j - 1];
                pk[j] = pk[j - 1];
                j--;
            }
            keyed[j] = aV;
            pk[j] = aK;
        }
        out = new address[](m);
        for (uint256 i = 0; i < m; i++) {
            out[i] = keyed[i];
        }
    }

    function _rollToEpoch(uint64 epoch) internal {
        vm.roll(uint256(epoch) * EPOCH_INTERVAL);
        assertEq(staking.currentEpoch(), epoch, "epoch roll mismatch");
    }

    /// @dev Ahead-commit model: `commitEpochCommittee` commits the next-uncommitted
    ///      epoch (lastCommittedEpochP1), gated `target <= currentEpoch+1`. Drive it
    ///      to catch up every uncommitted epoch through the current one, so
    ///      `getEpochCommittee(currentEpoch)` is populated — preserving the intent
    ///      of pre-change tests that did `_rollToEpoch(N); _commit();`.
    function _commit() internal {
        uint64 cur = staking.currentEpoch();
        while (staking.nextEpochToCommit() <= cur) {
            uint64 t = staking.nextEpochToCommit();
            // 2-epoch warm-up: committee[t] is selected from EffBal(t-2) (spec §4.4,
            // WARMUP_DELAY=2); genesis t<2 clamps to EffBal(0). The candidate is always
            // committed+verified now (no qualify-before-commit deferral anymore).
            address[] memory c = _canonicalAt(t < 2 ? 0 : t - 2);
            vm.prank(SYSTEM_CALLER);
            staking.commitEpochCommittee(c);
        }
    }

    /// @dev Commit the canonical committee for every uncommitted target strictly below
    ///      `target`, so the NEXT commit lands exactly on `target`. Used by the revert
    ///      tests to reach the first selection-eligible epoch.
    function _catchUpUntil(uint64 target) internal {
        while (staking.nextEpochToCommit() < target) {
            uint64 t = staking.nextEpochToCommit();
            address[] memory c = _canonicalAt(t < 2 ? 0 : t - 2);
            vm.prank(SYSTEM_CALLER);
            staking.commitEpochCommittee(c);
        }
    }

    function _singleton(address value) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _singleton16(uint16 value) internal pure returns (uint16[] memory values) {
        values = new uint16[](1);
        values[0] = value;
    }

    // --- dposActivationBlock / relative epoch numbering ---

    event DposActivationBlockChanged(uint64 prevValue, uint64 newValue);

    function test_dposActivationBlock_defaultsToZero() public view {
        assertEq(chainConfig.getDposActivationBlock(), 0);
    }

    function test_setDposActivationBlock_alignedFutureWorks() public {
        uint64 activation = 5 * EPOCH_INTERVAL; // aligned, >= block 1
        vm.expectEmit(false, false, false, true, address(chainConfig));
        emit DposActivationBlockChanged(0, activation);
        chainConfig.setDposActivationBlock(activation);
        assertEq(chainConfig.getDposActivationBlock(), activation);
    }

    function test_RevertIf_setDposActivationBlock_unaligned() public {
        vm.expectRevert(abi.encodeWithSignature("UnalignedActivationBlock()"));
        chainConfig.setDposActivationBlock(5 * EPOCH_INTERVAL + 1);
    }

    function test_RevertIf_setDposActivationBlock_inThePast() public {
        vm.roll(10 * EPOCH_INTERVAL);
        vm.expectRevert(abi.encodeWithSignature("ActivationBlockInPast()"));
        chainConfig.setDposActivationBlock(5 * EPOCH_INTERVAL);
    }

    function test_RevertIf_setDposActivationBlock_notGovernance() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSignature("OnlyGovernance()"));
        chainConfig.setDposActivationBlock(5 * EPOCH_INTERVAL);
    }

    /// `_currentEpoch` rebases to the activation block: epoch 0 starts at
    /// `activation`, advances every `EPOCH_INTERVAL`, and clamps to 0 before it.
    function test_currentEpoch_relativeToActivation() public {
        uint64 activation = 5 * EPOCH_INTERVAL;
        chainConfig.setDposActivationBlock(activation);

        vm.roll(activation - EPOCH_INTERVAL); // pre-activation
        assertEq(staking.currentEpoch(), 0, "pre-activation clamps to 0");

        vm.roll(activation); // exactly activation
        assertEq(staking.currentEpoch(), 0, "activation = relative epoch 0");

        vm.roll(activation + EPOCH_INTERVAL);
        assertEq(staking.currentEpoch(), 1);

        vm.roll(activation + 3 * EPOCH_INTERVAL + 1);
        assertEq(staking.currentEpoch(), 3);
    }

    function test_RevertIf_initialize_unalignedActivation() public {
        ChainConfig impl = new ChainConfig(
            IStaking(address(staking)),
            ISystemReward(address(systemReward)),
            IStakingPool(address(stakingPool)),
            IFluentGovernance(address(this)),
            IChainConfig(address(chainConfig)),
            blend
        );
        vm.expectRevert(abi.encodeWithSignature("UnalignedActivationBlock()"));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                ChainConfig.initialize,
                (
                    address(this),
                    ACTIVE_LEN,
                    EPOCH_INTERVAL,
                    uint32(150),
                    uint32(7),
                    uint32(7),
                    uint256(ONE),
                    uint256(ONE),
                    uint64(EPOCH_INTERVAL + 1), // unaligned
                    address(0),
                    address(0),
                    uint256(0)
                )
            )
        );
    }
}
