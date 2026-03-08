// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {RollupStorageLayout} from "../../contracts/rollup/RollupStorageLayout.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {MinimalTest} from "./Base.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract RollupStorageLayoutEnhancedTest is MinimalTest {
    Rollup internal rollup;
    address internal constant ADMIN = address(0x1111);
    address internal constant SEQUENCER = address(0x2222);
    address internal constant PAUSER = address(0x3333);
    address internal constant CHALLENGER = address(0x4444);
    address internal constant PROVER = address(0x5555);
    address internal constant VERIFIER = address(0x6666);
    address internal constant BRIDGE = address(0x7777);
    bytes32 internal constant PROGRAM_VKEY = keccak256("program_vkey");
    bytes32 internal constant GENESIS_HASH = keccak256("genesis");

    function setUp() public {
        Rollup rollupImpl = new Rollup();

        RollupStorageLayout.InitConfiguration memory config = RollupStorageLayout.InitConfiguration({
            admin: ADMIN,
            sequencer: SEQUENCER,
            pauser: PAUSER,
            challengeDepositAmount: 1 ether,
            challengeBlockCount: 100,
            approveBlockCount: 50,
            verifier: VERIFIER,
            programVKey: PROGRAM_VKEY,
            genesisHash: GENESIS_HASH,
            bridge: BRIDGE,
            batchSize: 10,
            acceptDepositDeadline: 1000,
            incentiveFee: 0.1 ether,
            challenger: CHALLENGER,
            prover: PROVER
        });

        bytes memory initData = abi.encodeCall(Rollup.initialize, (abi.encode(config)));
        rollup = Rollup(address(new ERC1967Proxy(address(rollupImpl), initData)));
    }

    // ========== Initialization Tests ==========

    function testInitializationSetsAllStorageCorrectly() public view {
        assertEq(rollup.bridge(), BRIDGE, "bridge mismatch");
        assertEq(rollup.verifier(), VERIFIER, "verifier mismatch");
        assertEq(rollup.programVKey(), PROGRAM_VKEY, "programVKey mismatch");
        assertEq(rollup.nextBatchIndex(), 1, "nextBatchIndex should be 1");
        assertEq(rollup.approveBlockCount(), 50, "approveBlockCount mismatch");
        assertEq(rollup.challengeDepositAmount(), 1 ether, "challengeDepositAmount mismatch");
        assertEq(rollup.incentiveFee(), 0.1 ether, "incentiveFee mismatch");
        assertEq(rollup.challengeBlockCount(), 100, "challengeBlockCount mismatch");
        assertEq(rollup.batchSize(), 10, "batchSize mismatch");
        assertEq(rollup.lastBlockHashInBatch(0), GENESIS_HASH, "genesis hash mismatch");
        assertEq(rollup.acceptDepositDeadline(), 1000, "acceptDepositDeadline mismatch");
        assertTrue(rollup.daCheck(), "daCheck should be true by default");
    }

    function testInitializationSetsRolesCorrectly() public view {
        assertTrue(rollup.hasRole(rollup.DEFAULT_ADMIN_ROLE(), ADMIN), "admin role not set");
        assertTrue(rollup.hasRole(rollup.SEQUENCER_ROLE(), SEQUENCER), "sequencer role not set");
        assertTrue(rollup.hasRole(rollup.PAUSER_ROLE(), PAUSER), "pauser role not set");
        assertTrue(rollup.hasRole(rollup.CHALLENGER_ROLE(), CHALLENGER), "challenger role not set");
        assertTrue(rollup.hasRole(rollup.PROVER_ROLE(), PROVER), "prover role not set");
    }

    function testInitializationRevertsOnZeroAdmin() public {
        Rollup rollupImpl = new Rollup();

        RollupStorageLayout.InitConfiguration memory config = RollupStorageLayout.InitConfiguration({
            admin: address(0),
            sequencer: SEQUENCER,
            pauser: PAUSER,
            challengeDepositAmount: 1 ether,
            challengeBlockCount: 100,
            approveBlockCount: 50,
            verifier: VERIFIER,
            programVKey: PROGRAM_VKEY,
            genesisHash: GENESIS_HASH,
            bridge: BRIDGE,
            batchSize: 10,
            acceptDepositDeadline: 1000,
            incentiveFee: 0.1 ether,
            challenger: CHALLENGER,
            prover: PROVER
        });

        bytes memory initData = abi.encodeCall(Rollup.initialize, (abi.encode(config)));

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroAddressNotAllowed.selector, "admin"));
        new ERC1967Proxy(address(rollupImpl), initData);
    }

    function testInitializationRevertsOnZeroVerifier() public {
        Rollup rollupImpl = new Rollup();

        RollupStorageLayout.InitConfiguration memory config = RollupStorageLayout.InitConfiguration({
            admin: ADMIN,
            sequencer: SEQUENCER,
            pauser: PAUSER,
            challengeDepositAmount: 1 ether,
            challengeBlockCount: 100,
            approveBlockCount: 50,
            verifier: address(0),
            programVKey: PROGRAM_VKEY,
            genesisHash: GENESIS_HASH,
            bridge: BRIDGE,
            batchSize: 10,
            acceptDepositDeadline: 1000,
            incentiveFee: 0.1 ether,
            challenger: CHALLENGER,
            prover: PROVER
        });

        bytes memory initData = abi.encodeCall(Rollup.initialize, (abi.encode(config)));

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroAddressNotAllowed.selector, "verifier"));
        new ERC1967Proxy(address(rollupImpl), initData);
    }

    function testInitializationRevertsOnZeroProgramVKey() public {
        Rollup rollupImpl = new Rollup();

        RollupStorageLayout.InitConfiguration memory config = RollupStorageLayout.InitConfiguration({
            admin: ADMIN,
            sequencer: SEQUENCER,
            pauser: PAUSER,
            challengeDepositAmount: 1 ether,
            challengeBlockCount: 100,
            approveBlockCount: 50,
            verifier: VERIFIER,
            programVKey: bytes32(0),
            genesisHash: GENESIS_HASH,
            bridge: BRIDGE,
            batchSize: 10,
            acceptDepositDeadline: 1000,
            incentiveFee: 0.1 ether,
            challenger: CHALLENGER,
            prover: PROVER
        });

        bytes memory initData = abi.encodeCall(Rollup.initialize, (abi.encode(config)));

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroValueNotAllowed.selector, "programVKey"));
        new ERC1967Proxy(address(rollupImpl), initData);
    }

    function testInitializationRevertsOnZeroGenesisHash() public {
        Rollup rollupImpl = new Rollup();

        RollupStorageLayout.InitConfiguration memory config = RollupStorageLayout.InitConfiguration({
            admin: ADMIN,
            sequencer: SEQUENCER,
            pauser: PAUSER,
            challengeDepositAmount: 1 ether,
            challengeBlockCount: 100,
            approveBlockCount: 50,
            verifier: VERIFIER,
            programVKey: PROGRAM_VKEY,
            genesisHash: bytes32(0),
            bridge: BRIDGE,
            batchSize: 10,
            acceptDepositDeadline: 1000,
            incentiveFee: 0.1 ether,
            challenger: CHALLENGER,
            prover: PROVER
        });

        bytes memory initData = abi.encodeCall(Rollup.initialize, (abi.encode(config)));

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroValueNotAllowed.selector, "genesisHash"));
        new ERC1967Proxy(address(rollupImpl), initData);
    }

    function testInitializationRevertsOnZeroBatchSize() public {
        Rollup rollupImpl = new Rollup();

        RollupStorageLayout.InitConfiguration memory config = RollupStorageLayout.InitConfiguration({
            admin: ADMIN,
            sequencer: SEQUENCER,
            pauser: PAUSER,
            challengeDepositAmount: 1 ether,
            challengeBlockCount: 100,
            approveBlockCount: 50,
            verifier: VERIFIER,
            programVKey: PROGRAM_VKEY,
            genesisHash: GENESIS_HASH,
            bridge: BRIDGE,
            batchSize: 0,
            acceptDepositDeadline: 1000,
            incentiveFee: 0.1 ether,
            challenger: CHALLENGER,
            prover: PROVER
        });

        bytes memory initData = abi.encodeCall(Rollup.initialize, (abi.encode(config)));

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroValueNotAllowed.selector, "batchSize"));
        new ERC1967Proxy(address(rollupImpl), initData);
    }

    // ========== Setter Tests ==========

    function testSetProgramVKeyUpdates() public {
        bytes32 newVKey = keccak256("new_vkey");

        vm.prank(ADMIN);
        rollup.setProgramVKey(newVKey);

        assertEq(rollup.programVKey(), newVKey, "programVKey should update");
    }

    function testSetProgramVKeyRevertsOnZero() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroValueNotAllowed.selector, "programVKey"));
        rollup.setProgramVKey(bytes32(0));
    }

    function testSetDaCheckToggles() public {
        assertTrue(rollup.daCheck(), "daCheck should be true initially");

        vm.prank(ADMIN);
        rollup.setDaCheck(false);

        assertEq(rollup.daCheck(), false, "daCheck should be false");

        vm.prank(ADMIN);
        rollup.setDaCheck(true);

        assertTrue(rollup.daCheck(), "daCheck should be true again");
    }

    function testSetBridgeUpdates() public {
        address newBridge = address(0x9999);

        vm.prank(ADMIN);
        rollup.setBridge(newBridge);

        assertEq(rollup.bridge(), newBridge, "bridge should update");
    }

    function testSetBridgeRevertsOnZeroAddress() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroAddressNotAllowed.selector, "bridge"));
        rollup.setBridge(address(0));
    }

    function testSetVerifierUpdates() public {
        address newVerifier = address(0x8888);

        vm.prank(ADMIN);
        rollup.setVerifier(newVerifier);

        assertEq(rollup.verifier(), newVerifier, "verifier should update");
    }

    function testSetVerifierRevertsOnZeroAddress() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroAddressNotAllowed.selector, "verifier"));
        rollup.setVerifier(address(0));
    }

    function testOnlyAdminCanCallSetters() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        rollup.setProgramVKey(keccak256("bad"));

        vm.prank(address(0xBAD));
        vm.expectRevert();
        rollup.setDaCheck(false);

        vm.prank(address(0xBAD));
        vm.expectRevert();
        rollup.setBridge(address(0x1));

        vm.prank(address(0xBAD));
        vm.expectRevert();
        rollup.setVerifier(address(0x1));
    }

    // ========== Pause Tests ==========

    function testPauserCanPause() public {
        vm.prank(PAUSER);
        rollup.pause();

        assertTrue(rollup.paused(), "contract should be paused");
    }

    function testPauserCanUnpause() public {
        vm.prank(PAUSER);
        rollup.pause();

        vm.prank(PAUSER);
        rollup.unpause();

        assertEq(rollup.paused(), false, "contract should be unpaused");
    }

    function testNonPauserCannotPause() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        rollup.pause();
    }

    // ========== View Function Tests ==========

    function testAcceptedBatchReturnsFalseForUnacceptedBatch() public view {
        assertEq(rollup.acceptedBatch(999), false, "unaccepted batch should return false");
    }

    function testApprovedBatchReturnsFalseForUnacceptedBatch() public view {
        assertEq(rollup.approvedBatch(999), false, "unapproved batch should return false");
    }

    function testRollupCorruptedReturnsFalseInitially() public view {
        assertEq(rollup.rollupCorrupted(), false, "rollup should not be corrupted initially");
    }

    function testGetChallengeQueueReturnsEmptyInitially() public view {
        bytes32[] memory queue = rollup.getChallengeQueue();
        assertEq(queue.length, 0, "challenge queue should be empty initially");
    }

    // ========== Storage Getter Tests ==========

    function testLastDepositAcceptedBlockNumberDefaultsToZero() public view {
        assertEq(rollup.lastDepositAcceptedBlockNumber(), 0, "should default to zero");
    }

    function testChallengerDepositDefaultsToZero() public view {
        assertEq(rollup.challengerDeposit(address(0x1234)), 0, "should default to zero");
    }

    function testChallengerReadyForWithdrawalDefaultsToZero() public view {
        assertEq(rollup.challengerReadyForWithdrawal(address(0x1234)), 0, "should default to zero");
    }

    function testProverReadyForWithdrawalDefaultsToZero() public view {
        assertEq(rollup.proverReadyForWithdrawal(address(0x1234)), 0, "should default to zero");
    }

    function testBlockCommitmentChallengerDefaultsToZero() public view {
        assertEq(rollup.blockCommitmentChallenger(keccak256("test")), address(0), "should default to zero");
    }

    function testChallengeDeadlineDefaultsToZero() public view {
        assertEq(rollup.challengeDeadline(keccak256("test")), 0, "should default to zero");
    }

    function testProvenBlockCommitmentDefaultsToFalse() public view {
        assertEq(rollup.provenBlockCommitment(keccak256("test")), false, "should default to false");
    }

    function testAlreadyApprovedBatchDefaultsToFalse() public view {
        assertEq(rollup.alreadyApprovedBatch(0), false, "should default to false");
    }

    // ========== Utility Function Tests ==========

    function testCalculateBlobHashProducesValidVersionedHash() public view {
        bytes memory testBlob = "test blob data";
        bytes32 hash = rollup.calculateBlobHash(testBlob);

        // Verify version byte is 0x01
        assertEq(uint8(hash[0]), 0x01, "first byte should be 0x01");
    }

    function testCalculateBatchRootForSingleCommitment() public view {
        RollupStorageLayout.BlockCommitment[] memory batch = new RollupStorageLayout.BlockCommitment[](1);
        batch[0] = RollupStorageLayout.BlockCommitment({
            previousBlockHash: keccak256("prev"),
            blockHash: keccak256("block"),
            withdrawalHash: keccak256("withdrawal"),
            depositHash: keccak256("deposit")
        });

        bytes32 root = rollup.calculateBatchRoot(batch);
        assertTrue(root != bytes32(0), "root should not be zero");
    }

    function testCalculateBatchRootForMultipleCommitments() public view {
        RollupStorageLayout.BlockCommitment[] memory batch = new RollupStorageLayout.BlockCommitment[](3);
        for (uint256 i = 0; i < 3; i++) {
            batch[i] = RollupStorageLayout.BlockCommitment({
                previousBlockHash: keccak256(abi.encodePacked("prev", i)),
                blockHash: keccak256(abi.encodePacked("block", i)),
                withdrawalHash: keccak256(abi.encodePacked("withdrawal", i)),
                depositHash: keccak256(abi.encodePacked("deposit", i))
            });
        }

        bytes32 root = rollup.calculateBatchRoot(batch);
        assertTrue(root != bytes32(0), "root should not be zero");
    }

    function testCalculateBatchRootIsDeterministic() public view {
        RollupStorageLayout.BlockCommitment[] memory batch = new RollupStorageLayout.BlockCommitment[](2);
        batch[0] = RollupStorageLayout.BlockCommitment({
            previousBlockHash: keccak256("prev1"),
            blockHash: keccak256("block1"),
            withdrawalHash: keccak256("withdrawal1"),
            depositHash: keccak256("deposit1")
        });
        batch[1] = RollupStorageLayout.BlockCommitment({
            previousBlockHash: keccak256("prev2"),
            blockHash: keccak256("block2"),
            withdrawalHash: keccak256("withdrawal2"),
            depositHash: keccak256("deposit2")
        });

        bytes32 root1 = rollup.calculateBatchRoot(batch);
        bytes32 root2 = rollup.calculateBatchRoot(batch);

        assertEq(root1, root2, "batch root should be deterministic");
    }

    // ========== Constants Tests ==========

    function testZeroBytesHashConstant() public view {
        assertEq(
            rollup.ZERO_BYTES_HASH(),
            0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470,
            "ZERO_BYTES_HASH constant mismatch"
        );
    }

    function testRoleConstants() public view {
        assertTrue(rollup.PAUSER_ROLE() == keccak256("PAUSER_ROLE"), "PAUSER_ROLE constant mismatch");
        assertTrue(rollup.SEQUENCER_ROLE() == keccak256("SEQUENCER_ROLE"), "SEQUENCER_ROLE constant mismatch");
        assertTrue(rollup.CHALLENGER_ROLE() == keccak256("CHALLENGER_ROLE"), "CHALLENGER_ROLE constant mismatch");
        assertTrue(rollup.PROVER_ROLE() == keccak256("PROVER_ROLE"), "PROVER_ROLE constant mismatch");
    }
}