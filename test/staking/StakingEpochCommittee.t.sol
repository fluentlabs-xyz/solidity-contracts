// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ChainConfig} from "../../contracts/staking/ChainConfig.sol";
import {SlashingIndicator} from "../../contracts/staking/SlashingIndicator.sol";
import {Staking} from "../../contracts/staking/Staking.sol";
import {BLS12381Verifier} from "../../contracts/libraries/BLS12381Verifier.sol";
import {StakingPool} from "../../contracts/staking/StakingPool.sol";
import {SystemReward} from "../../contracts/staking/SystemReward.sol";
import {MockBlendToken} from "../../contracts/staking/mocks/MockBlendToken.sol";
import {IChainConfig} from "../../contracts/staking/interfaces/IChainConfig.sol";
import {IFluentGovernance} from "../../contracts/staking/interfaces/IFluentGovernance.sol";
import {ISlashingIndicator} from "../../contracts/staking/interfaces/ISlashingIndicator.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {IStakingPool} from "../../contracts/staking/interfaces/IStakingPool.sol";
import {ISystemReward} from "../../contracts/staking/interfaces/ISystemReward.sol";

/// @title Epoch committee freeze + signer-index resolution tests
/// @notice Covers `commitEpochCommittee` (submit + verify) / `resolveSigner` /
///         `getEpochCommittee`.
contract StakingEpochCommitteeTest is Test {
    uint256 internal constant ONE = 1 ether;
    uint32 internal constant EPOCH_INTERVAL = 10; // ChainConfig.epochBlockInterval below
    uint32 internal constant ACTIVE_LEN = 60; // ChainConfig.activeValidatorsLength below
    uint64 internal constant RETENTION_MARGIN = 8; // Staking.EPOCH_COMMITTEE_RETENTION_MARGIN
    uint64 internal constant UNDELEGATE_PERIOD = 7; // ChainConfig.undelegatePeriod below
    // retention window = UNDELEGATE_PERIOD + RETENTION_MARGIN.

    Staking internal staking;
    StakingPool internal stakingPool;
    ChainConfig internal chainConfig;
    SlashingIndicator internal slashingIndicator;
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

    // --- ed25519 ordering conformance corpus (SINGLE SOURCE: crates/bls/
    //     tests/ed25519_ordering_conformance.rs — keep in sync in one PR). ---
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
        ISlashingIndicator predictedSlashingIndicator =
            ISlashingIndicator(vm.computeCreateAddress(address(this), nonce + 3));
        ISystemReward predictedSystemReward = ISystemReward(vm.computeCreateAddress(address(this), nonce + 5));
        IStakingPool predictedStakingPool = IStakingPool(vm.computeCreateAddress(address(this), nonce + 7));
        IChainConfig predictedChainConfig = IChainConfig(vm.computeCreateAddress(address(this), nonce + 9));
        IFluentGovernance governance = IFluentGovernance(address(this));

        Staking stakingImpl = new Staking(
            predictedStaking,
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig,
            blend
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

        SlashingIndicator slashingIndicatorImpl = new SlashingIndicator(
            predictedStaking,
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig,
            blend
        );
        slashingIndicator = SlashingIndicator(
            address(
                new ERC1967Proxy(
                    address(slashingIndicatorImpl), abi.encodeCall(SlashingIndicator.initialize, (address(this)))
                )
            )
        );

        SystemReward systemRewardImpl = new SystemReward(
            predictedStaking,
            predictedSlashingIndicator,
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
                        abi.encodeCall(SystemReward.initialize, (address(this), _singleton(address(0)), _singleton16(10_000)))
                    )
                )
            )
        );

        StakingPool stakingPoolImpl = new StakingPool(
            predictedStaking,
            predictedSlashingIndicator,
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
            predictedSlashingIndicator,
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
                            uint32(50),
                            uint32(150),
                            uint32(7),
                            uint32(7), // undelegatePeriod
                            uint256(ONE),
                            uint256(ONE)
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

    // ============ Writer (submit + verify) ============

    function test_commitEpochCommittee_acceptsCanonicalOrder() public {
        address a = _validator("A", bytes32(uint256(0x30)));
        address b = _validator("B", bytes32(uint256(0x10)));
        address c = _validator("C", bytes32(uint256(0x20)));

        _rollToEpoch(1);
        _commit();

        address[] memory got = staking.getEpochCommittee(1);
        assertEq(got.length, 3);
        assertEq(got[0], b); // 0x10
        assertEq(got[1], c); // 0x20
        assertEq(got[2], a); // 0x30
    }

    function test_commitEpochCommittee_excludesKeylessValidators() public {
        address a = _validator("A", bytes32(uint256(0x10)));
        staking.addValidator(makeAddr("keyless")); // no consensus keys
        address c = _validator("C", bytes32(uint256(0x20)));

        _rollToEpoch(1);
        _commit();

        address[] memory got = staking.getEpochCommittee(1);
        assertEq(got.length, 2);
        assertEq(got[0], a);
        assertEq(got[1], c);
    }

    function test_commitEpochCommittee_respectsTopKByStake() public {
        chainConfig.setActiveValidatorsLength(2);
        _validator("A", bytes32(uint256(0x10)));
        _validator("B", bytes32(uint256(0x20)));
        _validator("C", bytes32(uint256(0x30)));

        _rollToEpoch(1);
        _commit();

        assertEq(staking.getEpochCommittee(1).length, 2);
    }

    function test_commitEpochCommittee_idempotentSecondCallSameEpoch() public {
        address a = _validator("A", bytes32(uint256(0x10)));
        _rollToEpoch(1);
        _commit();
        _commit(); // no-op

        address[] memory got = staking.getEpochCommittee(1);
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

        address[] memory expected = new address[](2);
        expected[0] = a;
        expected[1] = b;
        vm.expectEmit(true, false, false, true, address(staking));
        emit EpochCommitteeCommitted(3, expected);
        vm.txGasPrice(0);
        vm.prank(sequencer);
        staking.commitEpochCommittee(expected);
    }

    function test_commitEpochCommittee_prunesEpochBeyondRetention() public {
        _validator("A", bytes32(uint256(0x10)));
        uint64 window = UNDELEGATE_PERIOD + RETENTION_MARGIN;

        _rollToEpoch(1);
        _commit();
        assertEq(staking.getEpochCommittee(1).length, 1);

        uint64 far = 1 + window + 1;
        _rollToEpoch(far);
        _commit();

        assertEq(staking.getEpochCommittee(1).length, 0, "stale epoch must be pruned");
        assertEq(staking.getEpochCommittee(far).length, 1, "current epoch retained");
    }

    function test_commitEpochCommittee_pruneCursorDoesNotLeakAcrossSkippedCommits() public {
        _validator("A", bytes32(uint256(0x10)));
        // commit epoch 1, then jump far ahead skipping every epoch in between;
        // the cursor must still reclaim epoch 1's storage.
        _rollToEpoch(1);
        _commit();
        _rollToEpoch(1 + UNDELEGATE_PERIOD + RETENTION_MARGIN + 5);
        _commit();
        assertEq(staking.getEpochCommittee(1).length, 0, "skipped-commit window must not leak");
    }

    function test_commitEpochCommittee_doesNotRewritePastEpoch() public {
        _validator("A", bytes32(uint256(0x10)));
        _rollToEpoch(5);
        _commit();

        _rollToEpoch(3);
        _commit(); // epoch 3 < lastCommitted 5 ⇒ no-op

        assertEq(staking.getEpochCommittee(3).length, 0, "past epoch must not be (re)written");
        assertEq(staking.getEpochCommittee(5).length, 1);
    }

    function test_RevertIf_commitEpochCommittee_notCoinbase() public {
        _validator("A", bytes32(uint256(0x10)));
        _rollToEpoch(1);
        address[] memory c = _canonical();
        vm.txGasPrice(0);
        vm.prank(makeAddr("notSequencer"));
        vm.expectRevert(abi.encodeWithSignature("OnlyCoinbase()"));
        staking.commitEpochCommittee(c);
    }

    function test_RevertIf_commitEpochCommittee_nonZeroGasPrice() public {
        _validator("A", bytes32(uint256(0x10)));
        _rollToEpoch(1);
        address[] memory c = _canonical();
        vm.txGasPrice(1);
        vm.prank(sequencer);
        vm.expectRevert(abi.encodeWithSignature("OnlyZeroGasPrice()"));
        staking.commitEpochCommittee(c);
        vm.txGasPrice(0);
    }

    function test_RevertIf_commitEpochCommittee_wrongOrder() public {
        address a = _validator("A", bytes32(uint256(0x10)));
        address b = _validator("B", bytes32(uint256(0x20)));
        _rollToEpoch(1);

        address[] memory bad = new address[](2);
        bad[0] = b; // 0x20 first — not strictly ascending
        bad[1] = a;
        vm.txGasPrice(0);
        vm.prank(sequencer);
        vm.expectRevert(abi.encodeWithSignature("CommitteeNotStrictlyAscending(address)", a));
        staking.commitEpochCommittee(bad);
    }

    function test_RevertIf_commitEpochCommittee_lengthMismatch() public {
        address a = _validator("A", bytes32(uint256(0x10)));
        _validator("B", bytes32(uint256(0x20)));
        _rollToEpoch(1);

        address[] memory bad = new address[](1);
        bad[0] = a; // only 1 of 2 keyed members
        vm.txGasPrice(0);
        vm.prank(sequencer);
        vm.expectRevert(abi.encodeWithSignature("CommitteeLengthMismatch(uint256,uint256)", uint256(2), uint256(1)));
        staking.commitEpochCommittee(bad);
    }

    function test_RevertIf_commitEpochCommittee_keylessMember() public {
        _validator("A", bytes32(uint256(0x10)));
        address b = _validator("B", bytes32(uint256(0x20)));
        address keyless = makeAddr("keyless");
        staking.addValidator(keyless);
        _rollToEpoch(1);

        // length == m (=2) but swaps a real keyed member for the keyless one.
        address[] memory bad = new address[](2);
        bad[0] = keyless;
        bad[1] = b;
        vm.txGasPrice(0);
        vm.prank(sequencer);
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
        _rollToEpoch(1);

        // length matches m(=2) but swaps a real member for the outsider
        address[] memory bad = new address[](2);
        bad[0] = outsider; // 0x05
        bad[1] = a; // 0x10
        vm.txGasPrice(0);
        vm.prank(sequencer);
        // outsider is keyed, so it passes the keyless check but fails set membership
        vm.expectRevert(abi.encodeWithSignature("CommitteeMemberNotInActiveSet(address)", outsider));
        staking.commitEpochCommittee(bad);
    }

    // ============ Resolver ============

    function test_resolveSigner_returnsValidatorAtSortedIndex() public {
        address a = _validator("A", bytes32(uint256(0x30)));
        address b = _validator("B", bytes32(uint256(0x10)));
        address c = _validator("C", bytes32(uint256(0x20)));
        _rollToEpoch(2);
        _commit();

        assertEq(staking.resolveSigner(2, 0), b);
        assertEq(staking.resolveSigner(2, 1), c);
        assertEq(staking.resolveSigner(2, 2), a);
    }

    function test_resolveSigner_matchesSimplexConformanceVectors() public {
        bytes32[10] memory corpus = _corpus();
        uint8[10] memory expected = _expectedSorted();

        address[10] memory v;
        for (uint256 i = 0; i < 10; i++) {
            v[i] = _validator(string.concat("conf", vm.toString(i)), corpus[i]);
        }

        _rollToEpoch(4);
        _commit(); // _canonical() reproduces the Simplex committee order

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
        _rollToEpoch(1);
        vm.txGasPrice(0);
        vm.prank(sequencer);
        vm.expectRevert(); // CommitteeNotStrictlyAscending at the first descending pair
        staking.commitEpochCommittee(seedOrder);
    }

    function test_resolveSigner_pastEpochUnaffectedByLaterStakeDrift() public {
        address a = _validator("A", bytes32(uint256(0x30)));
        address b = _validator("B", bytes32(uint256(0x10)));
        address c = _validator("C", bytes32(uint256(0x20)));
        _rollToEpoch(2);
        _commit();
        address[] memory snapshot = staking.getEpochCommittee(2);

        _validator("D", bytes32(uint256(0x05)));
        _validator("E", bytes32(uint256(0x40)));
        _rollToEpoch(3);
        _commit();

        address[] memory still = staking.getEpochCommittee(2);
        assertEq(still.length, snapshot.length);
        for (uint256 i = 0; i < snapshot.length; i++) {
            assertEq(still[i], snapshot[i]);
        }
        assertEq(staking.resolveSigner(2, 0), b);
        assertEq(staking.resolveSigner(2, 1), c);
        assertEq(staking.resolveSigner(2, 2), a);
        assertEq(staking.getEpochCommittee(3).length, 5);
    }

    function test_resolveSigner_pastEpochUnaffectedByLaterKChange() public {
        address a = _validator("A", bytes32(uint256(0x30)));
        address b = _validator("B", bytes32(uint256(0x10)));
        address c = _validator("C", bytes32(uint256(0x20)));
        _rollToEpoch(2);
        _commit();
        assertEq(staking.getEpochCommittee(2).length, 3);

        chainConfig.setActiveValidatorsLength(1);
        _rollToEpoch(3);
        _commit();

        assertEq(staking.resolveSigner(2, 0), b);
        assertEq(staking.resolveSigner(2, 1), c);
        assertEq(staking.resolveSigner(2, 2), a);
        assertEq(staking.getEpochCommittee(2).length, 3);
        assertEq(staking.getEpochCommittee(3).length, 1);
    }

    function test_RevertIf_resolveSigner_indexOutOfRange() public {
        _validator("A", bytes32(uint256(0x10)));
        _rollToEpoch(1);
        _commit();
        vm.expectRevert(
            abi.encodeWithSignature("SignerIndexOutOfRange(uint64,uint32,uint256)", uint64(1), uint32(5), uint256(1))
        );
        staking.resolveSigner(1, 5);
    }

    function test_RevertIf_resolveSigner_epochNotCommitted() public {
        vm.expectRevert(abi.encodeWithSignature("EpochCommitteeNotCommitted(uint64)", uint64(9)));
        staking.resolveSigner(9, 0);
    }

    function test_getEpochCommittee_emptyForUncommittedEpoch() public view {
        assertEq(staking.getEpochCommittee(42).length, 0);
    }

    // ============ Storage isolation ============

    function test_commitEpochCommittee_storageIsolatedFromOtherNamespaces() public {
        address a = _validator("A", bytes32(uint256(0x10)));
        (address ownerBefore, uint8 statusBefore,,,,,,,) = staking.getValidatorStatus(a);

        _rollToEpoch(1);
        _commit();

        (address ownerAfter, uint8 statusAfter,,,,,,,) = staking.getValidatorStatus(a);
        assertEq(ownerBefore, ownerAfter);
        assertEq(statusBefore, statusAfter);
        assertEq(staking.getConsensusKeys(a).peerPubkey, bytes32(uint256(0x10)));
    }

    // ============ Fuzz / scale ============

    function testFuzz_commitEpochCommittee_sortIsTotalOrder(uint256 seed) public {
        uint256 n = 8;
        for (uint256 i = 0; i < n; i++) {
            bytes32 peer = keccak256(abi.encode(seed, i));
            if (peer == bytes32(0)) peer = bytes32(uint256(1));
            _validator(string.concat("fz", vm.toString(i)), peer);
        }
        _rollToEpoch(1);
        _commit();

        address[] memory got = staking.getEpochCommittee(1);
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
        _rollToEpoch(1);
        _commit();

        address[] memory got = staking.getEpochCommittee(1);
        assertEq(got.length, 51);
        for (uint256 i = 1; i < got.length; i++) {
            assertTrue(
                staking.getConsensusKeys(got[i - 1]).peerPubkey < staking.getConsensusKeys(got[i]).peerPubkey,
                "not strictly ascending"
            );
        }
    }

    // ============ Helpers ============

    function _validator(string memory label, bytes32 peerPubkey) internal returns (address v) {
        v = makeAddr(label);
        staking.addValidator(v); // governance == address(this); owner == v
        vm.prank(v);
        staking.setConsensusKeys(v, PK_UNC, SIG_UNC_VALID, peerPubkey);
    }

    /// @dev Reproduces the contract's canonical committee off-chain: the keyed
    ///      subset of getValidators() top-k, sorted ascending by peerPubkey.
    function _canonical() internal view returns (address[] memory out) {
        address[] memory top = staking.getValidators();
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

    function _commit() internal {
        address[] memory c = _canonical();
        vm.txGasPrice(0);
        vm.prank(sequencer);
        staking.commitEpochCommittee(c);
    }

    function _singleton(address value) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _singleton16(uint16 value) internal pure returns (uint16[] memory values) {
        values = new uint16[](1);
        values[0] = value;
    }

    function _padBytes(uint256 len, uint8 b) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = bytes1(b);
        }
    }
}
