// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ChainConfig} from "../../contracts/staking/ChainConfig.sol";
import {SlashingIndicator} from "../../contracts/staking/SlashingIndicator.sol";
import {Staking} from "../../contracts/staking/Staking.sol";
import {StakingPool} from "../../contracts/staking/StakingPool.sol";
import {SystemReward} from "../../contracts/staking/SystemReward.sol";
import {MockBlendToken} from "../../contracts/staking/mocks/MockBlendToken.sol";
import {BLS12381Verifier} from "../../contracts/libraries/BLS12381Verifier.sol";
import {SimplexEvidenceDecoder} from "../../contracts/libraries/SimplexEvidenceDecoder.sol";
import {IChainConfig} from "../../contracts/staking/interfaces/IChainConfig.sol";
import {IFluentGovernance} from "../../contracts/staking/interfaces/IFluentGovernance.sol";
import {ISlashingIndicator} from "../../contracts/staking/interfaces/ISlashingIndicator.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {IStakingPool} from "../../contracts/staking/interfaces/IStakingPool.sol";
import {ISystemReward} from "../../contracts/staking/interfaces/ISystemReward.sol";

/// @title Equivocation (cryptographic double-sign) slashing tests.
/// @notice Conformance-pinned against
///         `crates/bls/tests/equivocation_evidence_conformance.rs`
///         (corpus mirrored by hand, reviewed in the same PR). Drives the
///         decoder against real Simplex consensus evidence (Commonware-encoded) and the full
///         on-chain slash path through the shipped `BLS12381Verifier`.
contract EquivocationSlashingTest is Test {
    uint256 internal constant ONE = 1 ether;
    uint32 internal constant EPOCH_INTERVAL = 10;
    uint32 internal constant ACTIVE_LEN = 60;
    uint64 internal constant CHAIN_ID = 20_994; // == fluent_namespace base in the corpus
    uint64 internal constant CORPUS_EPOCH = 7;
    uint32 internal constant CORPUS_SIGNER_IDX = 3;

    Staking internal staking;
    StakingPool internal stakingPool;
    ChainConfig internal chainConfig;
    SlashingIndicator internal slashingIndicator;
    SystemReward internal systemReward;
    MockBlendToken internal blend;
    BLS12381Verifier internal verifier;
    SimplexEvidenceDecoder internal decoder;

    address internal sequencer = makeAddr("sequencer");

    event EquivocationSlashed(address indexed validator, uint64 epoch, address indexed reporter);
    event ValidatorJailed(address indexed validator, uint64 epoch);

    // --- conformance corpus (SINGLE SOURCE: crates/bls/tests/
    //     equivocation_evidence_conformance.rs — keep in sync in one PR). ---
    // COMMITTEE in generation order; OFFENDER = index 0 (sorts to signerIdx 3).
    function _committee() internal pure returns (bytes32[4] memory peer, bytes[4] memory bls) {
        peer[0] = 0xff87a0b0a3c7c0ce827e9cada5ff79e75a44a0633bfcb5b50f99307ddb26b337;
        peer[1] = 0x2bd9a6a1b725644b7bfb9de3d3ba78158dfc9cd5eedbfdda5e134f311ffd50f3;
        peer[2] = 0x86f351ff4be28040d935afc005e52e04dffb657a1b4d50c74380b9f0fb23a325;
        peer[3] = 0xc4e5ac21f4ecc13c7b2af46549e1f6cd4f58d6ed5f997bf26b1d0247cf0be93f;
        bls[0] =
            hex"a0b5825c3dbaf52a1b20571d5925e944677d67b173100ea228cb38293f6e6f8d30ed9d9823250f2d7991640f4982493306b5c608826c61fe46820427bf25729c9f23127e072ddfeaf810db77af12076cdafac00980e6d4f5c2e3347053a3493d";
        bls[1] =
            hex"83e76182bdcacfc5e8cc2c483cf437e0ff855e866fa1f12a04d5b29db143dd08d8c22abe45a4e41b72cc40218cc3db9c0754513723b99e2ebb290ee1ad940f22da790adf98c4472e52e6fd5a177d54b916d57af9f89b196dfcbced5195c6294a";
        bls[2] =
            hex"a7efe3c63ab8d46fdf7171593c406e50940e0e74649f1e838f3dfbb4c1b57cd2a3531396e52b9fa7e102e0bc115de5c70dae1e0769fec9bbfddb13005c06a40f37ccef87ddc02615ccf41d141580766255ec0487754ca98e80bf81053071594a";
        bls[3] =
            hex"959ad814eb44847948c580b80ed4c93a72a83bc71a691f5ed34de3e6ec07254c04b5920ff9c92f0eb722a4ee60a46736122220d80bed7ce06a858de220927be7d89ae48e3474bcc1fd46a42f6c36478664899ac23eaa8e23868e8922223cebad";
    }

    // pk_unc is identical across all three vectors.
    function _pkUnc() internal pure returns (bytes memory) {
        return
        hex"0000000000000000000000000000000006b5c608826c61fe46820427bf25729c9f23127e072ddfeaf810db77af12076cdafac00980e6d4f5c2e3347053a3493d0000000000000000000000000000000000b5825c3dbaf52a1b20571d5925e944677d67b173100ea228cb38293f6e6f8d30ed9d9823250f2d7991640f49824933000000000000000000000000000000000b70c4b3fc082f10e64460dfe75ef87099cba2e9324416e7a37a679599fb54125ab10d594c18e8315d4d257ce2c8a1630000000000000000000000000000000010df56392d11ff44f778098bcb25487e92f066af30d7cdfada087e67bf0ca9a349436b8223db8ff241d364c5898319e9";
    }

    // PoP corpus mirror (generation order) from
    // crates/bls/tests/equivocation_evidence_conformance.rs COMMITTEE_POP.
    // setConsensusKeys now enforces on-chain PoP; each committee validator is
    // registered with its (blsPoP 48, blsPoPUncompressed 128, pkUncompressed
    // 256). ns = fluent_namespace(20994) (== vm.chainId(CHAIN_ID) in setUp).
    function _committeePop()
        internal
        pure
        returns (bytes[4] memory pop, bytes[4] memory popUnc, bytes[4] memory pkUnc)
    {
        pop[0] =
            hex"b5ed9e1bb8a7331d67438a6e1cde8012b0866ce30c70e3c028fd38bd7b5a2efa16ef920ad860a756a56e46eb3a8cbcca";
        popUnc[0] =
            hex"0000000000000000000000000000000015ed9e1bb8a7331d67438a6e1cde8012b0866ce30c70e3c028fd38bd7b5a2efa16ef920ad860a756a56e46eb3a8cbcca000000000000000000000000000000000f3c42a093b3d9bec7835bfde00481258c23f2356db273f37a01dd9ade643ec4c3d64556ae693bd8416e92151b237808";
        pkUnc[0] =
            hex"0000000000000000000000000000000006b5c608826c61fe46820427bf25729c9f23127e072ddfeaf810db77af12076cdafac00980e6d4f5c2e3347053a3493d0000000000000000000000000000000000b5825c3dbaf52a1b20571d5925e944677d67b173100ea228cb38293f6e6f8d30ed9d9823250f2d7991640f49824933000000000000000000000000000000000b70c4b3fc082f10e64460dfe75ef87099cba2e9324416e7a37a679599fb54125ab10d594c18e8315d4d257ce2c8a1630000000000000000000000000000000010df56392d11ff44f778098bcb25487e92f066af30d7cdfada087e67bf0ca9a349436b8223db8ff241d364c5898319e9";
        pop[1] =
            hex"b5573c800cf5f9bdd767738c7c348c65470aae9245cb8dc0758a7a5a52909f16f24f7a2a0d58e539be605236c87fcd5e";
        popUnc[1] =
            hex"0000000000000000000000000000000015573c800cf5f9bdd767738c7c348c65470aae9245cb8dc0758a7a5a52909f16f24f7a2a0d58e539be605236c87fcd5e00000000000000000000000000000000134033407922417ede483b9097fbea46c8e33b7e65b2215cd6aaf530f8bae20bcd463f4bc7966a00e04842d7f09d05e5";
        pkUnc[1] =
            hex"000000000000000000000000000000000754513723b99e2ebb290ee1ad940f22da790adf98c4472e52e6fd5a177d54b916d57af9f89b196dfcbced5195c6294a0000000000000000000000000000000003e76182bdcacfc5e8cc2c483cf437e0ff855e866fa1f12a04d5b29db143dd08d8c22abe45a4e41b72cc40218cc3db9c000000000000000000000000000000000790c173722ae98c675b64c59454de6bf8e8c09778c7e7ce20fe862d1e24d13cab70514875078a038d3cefc1fd95a7a5000000000000000000000000000000000bc092865b16d33244fd7d90d91e8dab11d80d2b25c6a6e21cf49460d40ed0860b12db5d1b7cb3e370d0c51ee9251573";
        pop[2] =
            hex"b07181278601fe711fc5b140bdb5b811076617356d59531226a7acc2049e5adf44ed42240d2a98ca15a74658ccc4f647";
        popUnc[2] =
            hex"00000000000000000000000000000000107181278601fe711fc5b140bdb5b811076617356d59531226a7acc2049e5adf44ed42240d2a98ca15a74658ccc4f647000000000000000000000000000000000e01bf22a8e266b300f93d149b60cf3c31bde77bb2e968d117079d4ff9a6ecdd0fef89ddb246fefc39b72da84e592e7c";
        pkUnc[2] =
            hex"000000000000000000000000000000000dae1e0769fec9bbfddb13005c06a40f37ccef87ddc02615ccf41d141580766255ec0487754ca98e80bf81053071594a0000000000000000000000000000000007efe3c63ab8d46fdf7171593c406e50940e0e74649f1e838f3dfbb4c1b57cd2a3531396e52b9fa7e102e0bc115de5c700000000000000000000000000000000022ee1dd2d9e8f7e1323378f46bd81b0117d1b1b4cc3846f6fa5707eb82fdef856e725abe6407c8fa9fb4263a6b1c96300000000000000000000000000000000139ed39eb9cf6f25b18c0212761eec0ba9dc2d2703559d1c85ba1eabd8afa5c99d0fa89b87a5eec0c9684907a5937de7";
        pop[3] =
            hex"8cd344ce1f254ae8a5cd2e707193486acc78a3bfcecd82b59ca73646ac993390516da42a4812c5413795368d5fa6bf40";
        popUnc[3] =
            hex"000000000000000000000000000000000cd344ce1f254ae8a5cd2e707193486acc78a3bfcecd82b59ca73646ac993390516da42a4812c5413795368d5fa6bf400000000000000000000000000000000008cc1d38dc6da92b614b647cd6dd4f51b1f7d3fdfccdcad3f64cc45c3ca7f0ff38660eb264e807bf143ae625d4f0ea1d";
        pkUnc[3] =
            hex"00000000000000000000000000000000122220d80bed7ce06a858de220927be7d89ae48e3474bcc1fd46a42f6c36478664899ac23eaa8e23868e8922223cebad00000000000000000000000000000000159ad814eb44847948c580b80ed4c93a72a83bc71a691f5ed34de3e6ec07254c04b5920ff9c92f0eb722a4ee60a46736000000000000000000000000000000000df0bc707524390953f6ddaf1a869fab68cdf6fb706d2b554baa4f8dacd8929bd2345715e53b2f14f7ffa24630b3450500000000000000000000000000000000050d7a0c974f61aaf8bae8f988cff852a55738674991364d48a2d137890de16fc05b111441265afb18e2568a6f9f800a";
    }

    // ---- conflicting_notarize vector ----
    function _cnEvidence() internal pure returns (bytes memory) {
        return
        hex"072a29aa000000000000000000000000000000000000000000000000000000000000aa038aa1d24f195fc333878b14744f62a363acf0051249c949c4cc473850991aa70841eea2171a333b13de2e61fed4936305072a29bb000000000000000000000000000000000000000000000000000000000000bb03923c9abd2f0abe63eed5a2d9ac175032b2b48685c61f9e6a7c8b7419d78077821d82a3bfd41a5f10bcfcd8434444f820";
    }

    function _cnMsg1() internal pure returns (bytes memory) {
        return hex"072a29aa000000000000000000000000000000000000000000000000000000000000aa";
    }

    function _cnSig1() internal pure returns (bytes memory) {
        return hex"8aa1d24f195fc333878b14744f62a363acf0051249c949c4cc473850991aa70841eea2171a333b13de2e61fed4936305";
    }

    function _cnMsg2() internal pure returns (bytes memory) {
        return hex"072a29bb000000000000000000000000000000000000000000000000000000000000bb";
    }

    function _cnSig2() internal pure returns (bytes memory) {
        return hex"923c9abd2f0abe63eed5a2d9ac175032b2b48685c61f9e6a7c8b7419d78077821d82a3bfd41a5f10bcfcd8434444f820";
    }

    function _cnSig1Unc() internal pure returns (bytes memory) {
        return
        hex"000000000000000000000000000000000aa1d24f195fc333878b14744f62a363acf0051249c949c4cc473850991aa70841eea2171a333b13de2e61fed49363050000000000000000000000000000000008a31fb618afd2019874641885fed0833ceaada142a5ff81cda50d437e14ba2c1e10e069b2de463d691d99d9c2168cf7";
    }

    function _cnSig2Unc() internal pure returns (bytes memory) {
        return
        hex"00000000000000000000000000000000123c9abd2f0abe63eed5a2d9ac175032b2b48685c61f9e6a7c8b7419d78077821d82a3bfd41a5f10bcfcd8434444f8200000000000000000000000000000000007d0660c235f4285a0552e8cd8820deeb134e43254f4e7ffc788a62d8bfbe759649fb840f1f2529ffdaf74c54a496df2";
    }

    // ---- conflicting_finalize vector ----
    function _cfEvidence() internal pure returns (bytes memory) {
        return
        hex"072a29cc000000000000000000000000000000000000000000000000000000000000cc039936ff0962301d36721c6d9e7947ec8a340bb9b5b7fcfa74ba2582918c9b3358b31c15c2a8ae372f3340e8c7706d32a6072a29dd000000000000000000000000000000000000000000000000000000000000dd03877570329a653f6cf0916cd5332247cd29a73d60a867dc1d710d5fe1bb4449b1e9393d5f9aed23bb08a2f9aed0e65af2";
    }

    function _cfMsg1() internal pure returns (bytes memory) {
        return hex"072a29cc000000000000000000000000000000000000000000000000000000000000cc";
    }

    function _cfSig1() internal pure returns (bytes memory) {
        return hex"9936ff0962301d36721c6d9e7947ec8a340bb9b5b7fcfa74ba2582918c9b3358b31c15c2a8ae372f3340e8c7706d32a6";
    }

    function _cfMsg2() internal pure returns (bytes memory) {
        return hex"072a29dd000000000000000000000000000000000000000000000000000000000000dd";
    }

    function _cfSig2() internal pure returns (bytes memory) {
        return hex"877570329a653f6cf0916cd5332247cd29a73d60a867dc1d710d5fe1bb4449b1e9393d5f9aed23bb08a2f9aed0e65af2";
    }

    function _cfSig1Unc() internal pure returns (bytes memory) {
        return
        hex"000000000000000000000000000000001936ff0962301d36721c6d9e7947ec8a340bb9b5b7fcfa74ba2582918c9b3358b31c15c2a8ae372f3340e8c7706d32a6000000000000000000000000000000000898025f48ea072c82938e3b8748d85f0f28a48a87131bfc5422d80427873db4441111b509967bc6eb0b673aa387ce46";
    }

    function _cfSig2Unc() internal pure returns (bytes memory) {
        return
        hex"00000000000000000000000000000000077570329a653f6cf0916cd5332247cd29a73d60a867dc1d710d5fe1bb4449b1e9393d5f9aed23bb08a2f9aed0e65af200000000000000000000000000000000018862d71974a29a8af65cf3f67b6817b5be4571e5a0962c89e37cbafb9cb58c3c4c434e3f005ac10c116b316d245a63";
    }

    // ---- nullify_finalize vector ----
    function _nfEvidence() internal pure returns (bytes memory) {
        return
        hex"072a03b9d1ed34ffda9193ce95eee9ab8db558f4e923a1b58a6f80ca0bf221f7567f72d65132b103190fd5c687f7f7a6cdc3db072a29ee000000000000000000000000000000000000000000000000000000000000ee0389eae226e709054f09892935d13772a1e73b62a8bfbd24e5f1f63617c5242714166f49b52ca5d97475b81820f75a6161";
    }

    function _nfMsg1() internal pure returns (bytes memory) {
        return hex"072a";
    }

    function _nfSig1() internal pure returns (bytes memory) {
        return hex"b9d1ed34ffda9193ce95eee9ab8db558f4e923a1b58a6f80ca0bf221f7567f72d65132b103190fd5c687f7f7a6cdc3db";
    }

    function _nfMsg2() internal pure returns (bytes memory) {
        return hex"072a29ee000000000000000000000000000000000000000000000000000000000000ee";
    }

    function _nfSig2() internal pure returns (bytes memory) {
        return hex"89eae226e709054f09892935d13772a1e73b62a8bfbd24e5f1f63617c5242714166f49b52ca5d97475b81820f75a6161";
    }

    function _nfSig1Unc() internal pure returns (bytes memory) {
        return
        hex"0000000000000000000000000000000019d1ed34ffda9193ce95eee9ab8db558f4e923a1b58a6f80ca0bf221f7567f72d65132b103190fd5c687f7f7a6cdc3db000000000000000000000000000000000d1b14ec4b4646e2c2f0a8ada516d162b402e9368c4b00d73a8132c3574cf965ab155be8e1d3b73089380ee371fc317d";
    }

    function _nfSig2Unc() internal pure returns (bytes memory) {
        return
        hex"0000000000000000000000000000000009eae226e709054f09892935d13772a1e73b62a8bfbd24e5f1f63617c5242714166f49b52ca5d97475b81820f75a6161000000000000000000000000000000000cfe5bc40869ff0b82cdcfed30c791be592b613d057b158b338285feafae5aab51ea9df43427006bdb71a4b60c78d5c1";
    }

    function setUp() public {
        vm.chainId(CHAIN_ID); // _fluentNamespace() == fluent_namespace(20994)
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

        verifier = new BLS12381Verifier();
        decoder = new SimplexEvidenceDecoder();
        chainConfig.setBlsVerifier(address(verifier));
        chainConfig.setEvidenceDecoder(address(decoder));

        vm.coinbase(sequencer);

        // Register the 4 committee validators + consensus keys, then freeze
        // the committee for epoch 7. OFFENDER (gen index 0) sorts to idx 3.
        _registerCommittee();
        _rollToEpoch(CORPUS_EPOCH);
        _commit();
    }

    address[4] internal validators;

    function _registerCommittee() internal {
        (bytes32[4] memory peer,) = _committee();
        (, bytes[4] memory popUnc, bytes[4] memory pkUnc) = _committeePop();
        for (uint256 i = 0; i < 4; i++) {
            address v = makeAddr(string.concat("val", vm.toString(i)));
            validators[i] = v;
            staking.addValidator(v);
            vm.prank(v);
            staking.setConsensusKeys(v, pkUnc[i], popUnc[i], peer[i]);
        }
    }

    function _offender() internal view returns (address) {
        return validators[0];
    }

    // ============ Decoder vs corpus ============

    function test_decode_conflictingNotarize_matchesCorpus() public view {
        SimplexEvidenceDecoder.Decoded memory d = decoder.decodeConflictingNotarize(_cnEvidence());
        assertEq(d.epoch, CORPUS_EPOCH);
        assertEq(d.signerIdx, CORPUS_SIGNER_IDX);
        assertEq(d.kind1, 0);
        assertEq(d.msg1, _cnMsg1());
        assertEq(d.sig1, _cnSig1());
        assertEq(d.kind2, 0);
        assertEq(d.msg2, _cnMsg2());
        assertEq(d.sig2, _cnSig2());
    }

    function test_decode_conflictingFinalize_matchesCorpus() public view {
        SimplexEvidenceDecoder.Decoded memory d = decoder.decodeConflictingFinalize(_cfEvidence());
        assertEq(d.epoch, CORPUS_EPOCH);
        assertEq(d.signerIdx, CORPUS_SIGNER_IDX);
        assertEq(d.kind1, 2);
        assertEq(d.msg1, _cfMsg1());
        assertEq(d.sig1, _cfSig1());
        assertEq(d.kind2, 2);
        assertEq(d.msg2, _cfMsg2());
        assertEq(d.sig2, _cfSig2());
    }

    function test_decode_nullifyFinalize_matchesCorpus() public view {
        SimplexEvidenceDecoder.Decoded memory d = decoder.decodeNullifyFinalize(_nfEvidence());
        assertEq(d.epoch, CORPUS_EPOCH);
        assertEq(d.signerIdx, CORPUS_SIGNER_IDX);
        assertEq(d.kind1, 1);
        assertEq(d.msg1, _nfMsg1());
        assertEq(d.sig1, _nfSig1());
        assertEq(d.kind2, 2);
        assertEq(d.msg2, _nfMsg2());
        assertEq(d.sig2, _nfSig2());
    }

    // ============ Decoder negative invariants ============

    function test_decode_rejectsSameProposal() public {
        // Make vote 2's (parent,payload) identical to vote 1's by copying
        // vote 1's proposal bytes over vote 2's region in a conflicting_notarize.
        bytes memory e = _cnEvidence();
        // layout: P1[0:35] A1[35:84] P2[84:119] A2[119:168]
        for (uint256 i = 0; i < 35; i++) {
            e[84 + i] = e[i];
        }
        vm.expectRevert(SimplexEvidenceDecoder.InvalidEvidence.selector);
        decoder.decodeConflictingNotarize(e);
    }

    function test_decode_rejectsSignerMismatch() public {
        bytes memory e = _cnEvidence();
        // A2.signer is the first byte of attestation 2 at offset 119.
        e[119] = bytes1(uint8(e[119]) + 1);
        vm.expectRevert(SimplexEvidenceDecoder.InvalidEvidence.selector);
        decoder.decodeConflictingNotarize(e);
    }

    function test_decode_rejectsRoundMismatch() public {
        bytes memory e = _nfEvidence();
        // nullify Round = bytes [0:2] (epoch=07, view=2a). Bump the finalize
        // proposal's epoch (offset 2: first byte of P2.Round) so rounds differ.
        e[2] = bytes1(uint8(e[2]) + 1);
        vm.expectRevert(SimplexEvidenceDecoder.InvalidEvidence.selector);
        decoder.decodeNullifyFinalize(e);
    }

    // ============ End-to-end slash ============

    function _assertSlashed(address v) internal view {
        (, uint8 status,,,,,,,) = staking.getValidatorStatus(v);
        assertEq(uint256(status), uint256(3), "must be Jail"); // ValidatorStatus.Jail
        // Permanence is enforced by the `tombstoned` flag and asserted in
        // test_RevertIf_releaseValidatorFromJail_tombstoned.
        address[] memory active = staking.getValidators();
        for (uint256 i = 0; i < active.length; i++) {
            assertTrue(active[i] != v, "must be removed from active set");
        }
    }

    function test_slashEquivocationNotarize_validEvidence_tombstones() public {
        vm.expectEmit(true, false, true, true, address(staking));
        emit EquivocationSlashed(_offender(), CORPUS_EPOCH, address(this));
        staking.slashEquivocationNotarize(_cnEvidence(), _pkUnc(), _cnSig1Unc(), _cnSig2Unc());
        _assertSlashed(_offender());
    }

    function test_slashEquivocationFinalize_validEvidence_tombstones() public {
        vm.expectEmit(true, false, true, true, address(staking));
        emit EquivocationSlashed(_offender(), CORPUS_EPOCH, address(this));
        staking.slashEquivocationFinalize(_cfEvidence(), _pkUnc(), _cfSig1Unc(), _cfSig2Unc());
        _assertSlashed(_offender());
    }

    function test_slashEquivocationNullifyFinalize_validEvidence_tombstones() public {
        vm.expectEmit(true, false, true, true, address(staking));
        emit EquivocationSlashed(_offender(), CORPUS_EPOCH, address(this));
        staking.slashEquivocationNullifyFinalize(_nfEvidence(), _pkUnc(), _nfSig1Unc(), _nfSig2Unc());
        _assertSlashed(_offender());
    }

    // ============ Replay / permanence ============

    function test_RevertIf_slashEquivocation_replay() public {
        staking.slashEquivocationNotarize(_cnEvidence(), _pkUnc(), _cnSig1Unc(), _cnSig2Unc());
        vm.expectRevert(
            abi.encodeWithSignature("AlreadySlashedForEquivocation(address)", _offender())
        );
        staking.slashEquivocationFinalize(_cfEvidence(), _pkUnc(), _cfSig1Unc(), _cfSig2Unc());
    }

    function test_RevertIf_releaseValidatorFromJail_tombstoned() public {
        staking.slashEquivocationNotarize(_cnEvidence(), _pkUnc(), _cnSig1Unc(), _cnSig2Unc());
        vm.prank(_offender()); // owner == validator (addValidator default)
        vm.expectRevert(
            abi.encodeWithSignature("AlreadySlashedForEquivocation(address)", _offender())
        );
        staking.releaseValidatorFromJail(_offender());
    }

    function test_RevertIf_setConsensusKeys_tombstoned() public {
        staking.slashEquivocationNotarize(_cnEvidence(), _pkUnc(), _cnSig1Unc(), _cnSig2Unc());
        (bytes32[4] memory peer,) = _committee();
        (, bytes[4] memory popUnc, bytes[4] memory pkUnc) = _committeePop();
        vm.prank(_offender());
        vm.expectRevert(
            abi.encodeWithSignature("AlreadySlashedForEquivocation(address)", _offender())
        );
        // Reverts at the tombstone guard (precedes all length/PoP checks).
        staking.setConsensusKeys(_offender(), pkUnc[0], popUnc[0], peer[0]);
    }

    // ============ Invalid signature ============

    function test_RevertIf_slashEquivocation_signatureInvalid() public {
        bytes memory badSig = _cnSig1Unc();
        badSig[40] = bytes1(uint8(badSig[40]) ^ 0xff); // corrupt G1 x byte
        // compressG1(badSig) != ev.sig1 ⇒ caught by the Staking-side binding.
        vm.expectRevert(abi.encodeWithSignature("EquivocationSignatureInvalid()"));
        staking.slashEquivocationNotarize(_cnEvidence(), _pkUnc(), badSig, _cnSig2Unc());
    }

    function test_RevertIf_slashEquivocation_keyMismatch() public {
        (,, bytes[4] memory pkUnc) = _committeePop();
        // A valid but WRONG pubkey (another committee member) must not slash:
        // compressG2(pkUnc[1]) != the offender's stored compressed key.
        vm.expectRevert(abi.encodeWithSignature("EquivocationKeyMismatch()"));
        staking.slashEquivocationNotarize(_cnEvidence(), pkUnc[1], _cnSig1Unc(), _cnSig2Unc());
    }

    // ============ Decoder error propagation ============

    function test_RevertIf_slashEquivocation_epochNotCommitted() public {
        // Tamper the evidence so the round epoch is 8 (never committed) on
        // both proposals; the resolver's EpochCommitteeNotCommitted must
        // propagate. P1.epoch is offset 0; P2.epoch offset 84.
        bytes memory e = _cnEvidence();
        e[0] = 0x08;
        e[84] = 0x08;
        vm.expectRevert(abi.encodeWithSignature("EpochCommitteeNotCommitted(uint64)", uint64(8)));
        staking.slashEquivocationNotarize(e, _pkUnc(), _cnSig1Unc(), _cnSig2Unc());
    }

    function test_RevertIf_slashEquivocation_signerIndexOutOfRange() public {
        // signerIdx is at offset 35 (A1) and 119 (A2). Set to 9 (>= committee
        // length 4) on both votes; the same-signer invariant still holds.
        bytes memory e = _cnEvidence();
        e[35] = 0x09;
        e[119] = 0x09;
        vm.expectRevert(
            abi.encodeWithSignature("SignerIndexOutOfRange(uint64,uint32,uint256)", uint64(7), uint32(9), uint256(4))
        );
        staking.slashEquivocationNotarize(e, _pkUnc(), _cnSig1Unc(), _cnSig2Unc());
    }

    // ============ Permissionless ============

    function test_slashEquivocation_permissionless_anyCaller() public {
        address rando = makeAddr("rando");
        vm.expectEmit(true, false, true, true, address(staking));
        emit EquivocationSlashed(_offender(), CORPUS_EPOCH, rando);
        vm.prank(rando);
        staking.slashEquivocationNotarize(_cnEvidence(), _pkUnc(), _cnSig1Unc(), _cnSig2Unc());
        _assertSlashed(_offender());
    }

    // ============ Storage isolation ============

    function test_slashEquivocation_storageIsolated() public {
        // Slashing the offender must not touch the other validators'
        // status/keys (separate ERC-7201 namespace).
        (bytes32[4] memory peer,) = _committee();
        staking.slashEquivocationNotarize(_cnEvidence(), _pkUnc(), _cnSig1Unc(), _cnSig2Unc());
        for (uint256 i = 1; i < 4; i++) {
            (, uint8 status,,,,,,,) = staking.getValidatorStatus(validators[i]);
            assertEq(uint256(status), uint256(1), "untouched validator must stay Active");
            assertEq(staking.getConsensusKeys(validators[i]).peerPubkey, peer[i]);
        }
    }

    // ============ Helpers ============

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
}
