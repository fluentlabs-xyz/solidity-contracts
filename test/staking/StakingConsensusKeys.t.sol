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

contract StakingConsensusKeysTest is Test {
    uint256 internal constant ONE = 1 ether;

    Staking internal staking;
    StakingPool internal stakingPool;
    ChainConfig internal chainConfig;
    SlashingIndicator internal slashingIndicator;
    SystemReward internal systemReward;
    MockBlendToken internal blend;
    BLS12381Verifier internal verifier;

    address internal validator1 = makeAddr("validator1");
    address internal validator2 = makeAddr("validator2");
    address internal validator3 = makeAddr("validator3");
    address internal staker1 = makeAddr("staker1");

    // Committed PoP vector — hand-mirrored from the conformance corpus
    // `crates/bls/tests/hash_to_g1_conformance.rs` (`verify_pop_valid`,
    // chain_id C_MAIN=20994) via `test/bls/BlsHashToG1Conformance.t.sol`.
    // PoP has NO address binding, so this single tuple is a valid
    // registration for ANY validator address.
    bytes internal constant PK_REF =
        hex"92b050b6fbe80695b5d56835e978918e37c8707a7fad09a01ae782d4c3170c9baa4c2c196b36eac6b78ceb210b287aeb0727ef1c60e48042142f7bcc8b6382305cd50c5a4542c44ec72a4de6640c194f8ef36bea1dbed168ab6fd8681d910d55";
    bytes internal constant PK_UNC =
        hex"000000000000000000000000000000000727ef1c60e48042142f7bcc8b6382305cd50c5a4542c44ec72a4de6640c194f8ef36bea1dbed168ab6fd8681d910d550000000000000000000000000000000012b050b6fbe80695b5d56835e978918e37c8707a7fad09a01ae782d4c3170c9baa4c2c196b36eac6b78ceb210b287aeb000000000000000000000000000000000f9da5ef5089f62dc55ec91c2459f6ed3fd9981f8d4926ad90dca0314603ae4af86c8fa12bdd2569867f05a24908b7fc0000000000000000000000000000000009ac1ba2c6341d99ba0d6bfab8ea6a3a58726e787ab22b899cd95acfec350c1fc09f5fcbbef992106b61e45eb9158354";
    bytes internal constant SIG_REF_VALID =
        hex"a27ecd57f1889127d81b2a3c46e1905c419302192ebc90f818c7d272b38a6495337f7dde0733d0d431fc1338e8caf62e";
    bytes internal constant SIG_UNC_VALID =
        hex"00000000000000000000000000000000027ecd57f1889127d81b2a3c46e1905c419302192ebc90f818c7d272b38a6495337f7dde0733d0d431fc1338e8caf62e00000000000000000000000000000000109a4722abb94b2ffb8685abe75b4fc8336d2f6534b64fee49baa07ab7357de65036fb93ee119860768cc65daa4c7b1e";
    bytes internal constant SIG_REF_TAMPERED =
        hex"9733f7c8769099b3c5f2601d80aec5f35b4e0086b9d4f2092140e0f40002c328ceb71b469d9456ed4caa27e340a78d9b";
    bytes internal constant SIG_UNC_TAMPERED =
        hex"000000000000000000000000000000001733f7c8769099b3c5f2601d80aec5f35b4e0086b9d4f2092140e0f40002c328ceb71b469d9456ed4caa27e340a78d9b00000000000000000000000000000000058d6642e4126b5d37407dcb4a34911ceab3992b1524ce67bf5fdd2688374a692839dba9ac3ba6ab3305cf51200d49ca";

    bytes32 internal validPeerPk = bytes32(uint256(1));
    bytes32 internal validPeerPk2 = bytes32(uint256(2));

    event ConsensusKeysSet(address indexed validator, bytes blsPubkey, bytes32 peerPubkey, uint64 activationEpoch);

    function setUp() public {
        blend = new MockBlendToken();
        _fund(staker1);
        _fund(validator1);
        _fund(validator2);
        _fund(validator3);

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
            payable(address(
                    new ERC1967Proxy(
                        address(stakingImpl),
                        abi.encodeCall(
                            Staking.initialize, (address(this), new address[](0), new uint256[](0), uint16(0))
                        )
                    )
                ))
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
            payable(address(
                    new ERC1967Proxy(
                        address(systemRewardImpl),
                        abi.encodeCall(
                            SystemReward.initialize, (address(this), _singleton(address(0)), _singleton16(10_000))
                        )
                    )
                ))
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
            payable(address(
                    new ERC1967Proxy(address(stakingPoolImpl), abi.encodeCall(StakingPool.initialize, (address(this))))
                ))
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
                            uint32(60),
                            uint32(10),
                            uint32(50),
                            uint32(150),
                            uint32(7),
                            uint32(7),
                            uint256(ONE),
                            uint256(ONE)
                        )
                    )
                )
            )
        );

        assertEq(address(staking), address(predictedStaking));
        assertEq(address(slashingIndicator), address(predictedSlashingIndicator));
        assertEq(address(systemReward), address(predictedSystemReward));
        assertEq(address(stakingPool), address(predictedStakingPool));
        assertEq(address(chainConfig), address(predictedChainConfig));

        // On-chain PoP wiring: deploy + govern-register the verifier, and pin
        // block.chainid to the corpus chain (20994) so _fluentNamespace()
        // equals the namespace the committed PoP vector was signed under.
        verifier = new BLS12381Verifier();
        chainConfig.setBlsVerifier(address(verifier));
        vm.chainId(20994);

        // governance-add validator1 (we are governance via constructor) so msg.sender (this) is owner
        staking.addValidator(validator1);
        staking.addValidator(validator2);
        staking.addValidator(validator3);
    }

    // ============ Happy path ============

    function test_setConsensusKeys_succeeds() public {
        uint64 expectedEpoch = staking.nextEpoch();
        _okKeys(validator1, validPeerPk);

        IStaking.ConsensusKeys memory k = staking.getConsensusKeys(validator1);
        assertEq(k.blsPubkey, PK_REF);
        assertEq(k.peerPubkey, validPeerPk);
        assertEq(k.activationEpoch, expectedEpoch);
    }

    function test_setConsensusKeys_emitsEvent() public {
        uint64 expectedEpoch = staking.nextEpoch();
        vm.expectEmit(true, false, false, true, address(staking));
        emit ConsensusKeysSet(validator1, PK_REF, validPeerPk, expectedEpoch);
        _okKeys(validator1, validPeerPk);
    }

    // ============ Reverts (pre-PoP guards) ============

    function test_setConsensusKeys_revertsOnUnknownValidator() public {
        address unknown = makeAddr("unknown");
        vm.expectRevert(abi.encodeWithSignature("ValidatorNotFound(address)", unknown));
        staking.setConsensusKeys(unknown, PK_UNC, SIG_UNC_VALID, validPeerPk);
    }

    function test_setConsensusKeys_revertsOnWrongOwner() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OnlyValidatorOwner(address)", validator1));
        staking.setConsensusKeys(validator1, PK_UNC, SIG_UNC_VALID, validPeerPk);
    }

    function test_setConsensusKeys_revertsOnInvalidPubkeyLength() public {
        // blsPubkeyUncompressed too short (must be 256 B).
        bytes memory badPkUnc = hex"deadbeef";
        vm.prank(validator1);
        vm.expectRevert(abi.encodeWithSignature("InvalidConsensusKeyEncoding()"));
        staking.setConsensusKeys(validator1, badPkUnc, SIG_UNC_VALID, validPeerPk);
    }

    function test_setConsensusKeys_revertsOnPubkeyTooLong() public {
        // blsPubkeyUncompressed wrong length (128, must be 256 B).
        bytes memory badPkUnc = _padBytes(128, 0xAA);
        vm.prank(validator1);
        vm.expectRevert(abi.encodeWithSignature("InvalidConsensusKeyEncoding()"));
        staking.setConsensusKeys(validator1, badPkUnc, SIG_UNC_VALID, validPeerPk);
    }

    function test_setConsensusKeys_revertsOnBadEncoding() public {
        // blsPubkeyUncompressed length OK (256) but blsPoPUncompressed wrong.
        vm.prank(validator1);
        vm.expectRevert(abi.encodeWithSignature("InvalidConsensusKeyEncoding()"));
        staking.setConsensusKeys(validator1, PK_UNC, hex"00", validPeerPk);
    }

    function test_setConsensusKeys_revertsOnAlreadySet() public {
        _okKeys(validator1, validPeerPk);

        // Second call: valid-length args reach the AlreadySet guard (which
        // precedes PoP verification) and revert there.
        vm.prank(validator1);
        vm.expectRevert(abi.encodeWithSignature("ConsensusKeysAlreadySet(address)", validator1));
        staking.setConsensusKeys(validator1, PK_UNC, SIG_UNC_VALID, validPeerPk2);
    }

    // ============ Reverts (PoP / verifier) ============

    function test_setConsensusKeys_revertsOnInvalidPoP() public {
        // Tampered PoP is a well-formed G1 point, so the pairing fails ⇒
        // verify() returns false ⇒ explicit revert.
        vm.prank(validator1);
        vm.expectRevert(abi.encodeWithSignature("InvalidProofOfPossession(address)", validator1));
        staking.setConsensusKeys(validator1, PK_UNC, SIG_UNC_TAMPERED, validPeerPk);
    }

    function test_setConsensusKeys_revertsWhenVerifierUnset() public {
        chainConfig.setBlsVerifier(address(0));
        vm.prank(validator1);
        vm.expectRevert(abi.encodeWithSignature("BlsVerifierNotConfigured()"));
        staking.setConsensusKeys(validator1, PK_UNC, SIG_UNC_VALID, validPeerPk);
    }

    function test_setConsensusKeys_storesCompressedFromUncompressed() public {
        // The stored 96 B identity is compressed on-chain from the supplied
        // uncompressed pubkey — must equal the corpus compressed vector.
        _okKeys(validator1, validPeerPk);
        assertEq(staking.getConsensusKeys(validator1).blsPubkey, PK_REF);
    }

    // ============ Views ============

    function test_getConsensusKeys_returnsEmptyForUnset() public view {
        IStaking.ConsensusKeys memory k = staking.getConsensusKeys(validator2);
        assertEq(k.blsPubkey.length, 0);
        assertEq(k.peerPubkey, bytes32(0));
        assertEq(k.activationEpoch, 0);
    }

    function test_getValidatorsWithKeys_returnsAll() public {
        // PoP has no address binding ⇒ the same valid pubkey registers for
        // both; per-validator distinctness is asserted via peerPubkey.
        _okKeys(validator1, validPeerPk);
        _okKeys(validator2, validPeerPk2);

        (address[] memory addrs, IStaking.ConsensusKeys[] memory keys) = staking.getValidatorsWithKeys();

        // Validate that array lengths align.
        assertEq(addrs.length, keys.length);

        // We expect validator1, validator2, validator3 in the active set.
        // The order is determined by getValidators(); we check by address.
        uint256 found1 = type(uint256).max;
        uint256 found2 = type(uint256).max;
        uint256 found3 = type(uint256).max;
        for (uint256 i = 0; i < addrs.length; i++) {
            if (addrs[i] == validator1) found1 = i;
            else if (addrs[i] == validator2) found2 = i;
            else if (addrs[i] == validator3) found3 = i;
        }
        assertTrue(found1 != type(uint256).max);
        assertTrue(found2 != type(uint256).max);
        assertTrue(found3 != type(uint256).max);

        assertEq(keys[found1].blsPubkey, PK_REF);
        assertEq(keys[found1].peerPubkey, validPeerPk);

        assertEq(keys[found2].blsPubkey, PK_REF);
        assertEq(keys[found2].peerPubkey, validPeerPk2);

        // validator3 — no keys set, must return empty struct.
        assertEq(keys[found3].blsPubkey.length, 0);
        assertEq(keys[found3].peerPubkey, bytes32(0));
        assertEq(keys[found3].activationEpoch, 0);
    }

    // ============ Storage isolation ============

    function test_consensusKeysStorage_doesNotInterfereWithStakingStorage() public {
        (address ownerBefore, uint8 statusBefore,,,,,,,) = staking.getValidatorStatus(validator1);

        _okKeys(validator1, validPeerPk);

        (address ownerAfter, uint8 statusAfter,,,,,,,) = staking.getValidatorStatus(validator1);

        assertEq(ownerBefore, ownerAfter);
        assertEq(statusBefore, statusAfter);
    }

    // ============ Scale test ============

    function test_getValidatorsWithKeys_n51() public {
        // Add 48 more validators to reach 51 total (validator1, validator2, validator3 added in setUp).
        address[] memory extra = new address[](48);
        for (uint256 i = 0; i < 48; i++) {
            extra[i] = makeAddr(string.concat("scaleValidator", vm.toString(i)));
            staking.addValidator(extra[i]);
        }

        _okKeys(validator1, validPeerPk);
        for (uint256 i = 0; i < 48; i++) {
            _okKeys(extra[i], bytes32(uint256(100 + i)));
        }

        (address[] memory addrs, IStaking.ConsensusKeys[] memory keys) = staking.getValidatorsWithKeys();
        assertEq(addrs.length, 51);
        assertEq(keys.length, 51);

        // Sanity: validator1's keys are populated.
        uint256 found1 = type(uint256).max;
        for (uint256 i = 0; i < addrs.length; i++) {
            if (addrs[i] == validator1) {
                found1 = i;
                break;
            }
        }
        assertTrue(found1 != type(uint256).max);
        assertEq(keys[found1].blsPubkey, PK_REF);
    }

    // ============ Helpers ============

    /// @dev Register the committed valid PoP vector for `who` (PoP has no
    ///      address binding, so the single vector is valid for any address).
    function _okKeys(address who, bytes32 peer) internal {
        vm.prank(who);
        staking.setConsensusKeys(who, PK_UNC, SIG_UNC_VALID, peer);
    }

    function _fund(address account) internal {
        blend.mint(account, 1_000_000 ether);
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
