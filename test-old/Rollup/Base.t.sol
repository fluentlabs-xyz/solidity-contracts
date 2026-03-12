// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {RollupStorageLayout} from "../../contracts/rollup/RollupStorageLayout.sol";

abstract contract RollupBase is Test {
    // ============ Actors ============

    address internal admin = makeAddr("admin");
    address internal sequencer = makeAddr("sequencer");
    address internal challenger = makeAddr("challenger");
    address internal prover = makeAddr("prover");
    address internal preconfirmer = makeAddr("preconfirmer");

    // ============ Contracts ============

    Rollup internal rollup;

    // ============ Constants ============

    bytes32 internal constant GENESIS_HASH = keccak256("genesis");
    bytes32 internal constant PROGRAM_VKEY = keccak256("vkey");
    uint256 internal constant BATCH_SIZE = 4;
    uint256 internal constant CHALLENGE_DEPOSIT = 1 ether;
    uint256 internal constant CHALLENGE_BLOCK_COUNT = 100;
    uint256 internal constant APPROVE_BLOCK_COUNT = 50;

    // ============ Setup ============

    function setUp() public virtual {
        rollup = _deployRollup();
    }

    function _deployRollup() internal returns (Rollup) {
        address sp1Verifier = _deployMockSp1Verifier();

        RollupStorageLayout.InitConfiguration memory cfg = RollupStorageLayout.InitConfiguration({
            admin: admin,
            sequencer: sequencer,
            pauser: admin,
            challenger: challenger,
            prover: prover,
            preconfirmationRole: preconfirmer,
            sp1Verifier: sp1Verifier,
            programVKey: PROGRAM_VKEY,
            genesisHash: GENESIS_HASH,
            bridge: makeAddr("bridge"),
            batchSize: BATCH_SIZE,
            challengeDepositAmount: CHALLENGE_DEPOSIT,
            challengeBlockCount: CHALLENGE_BLOCK_COUNT,
            approveBlockCount: APPROVE_BLOCK_COUNT,
            acceptDepositDeadline: 1000,
            incentiveFee: 0.1 ether,
            nitroVerifier: address(0)
        });

        Rollup impl = new Rollup();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Rollup.initialize, (abi.encode(cfg))));

        Rollup r = Rollup(address(proxy));

        // disable DA check so tests don't need blobs
        vm.prank(admin);
        r.setDaCheck(false);

        return r;
    }

    // ============ Helpers ============

    /// @dev Build a minimal valid batch of block commitments chained from a given parent hash.
    function _makeBatch(bytes32 parentHash) internal pure returns (RollupStorageLayout.BlockCommitment[] memory batch) {
        batch = new RollupStorageLayout.BlockCommitment[](BATCH_SIZE);
        bytes32 prev = parentHash;
        for (uint256 i = 0; i < BATCH_SIZE; i++) {
            bytes32 blockHash = keccak256(abi.encode("block", i, prev));
            batch[i] = RollupStorageLayout.BlockCommitment({
                previousBlockHash: prev,
                blockHash: blockHash,
                sentMessageRoot: bytes32(0),
                receivedMessageRoot: bytes32(0),
                receivedMessageCount: 0
            });
            prev = blockHash;
        }
    }

    /// @dev Accept the next batch as sequencer and return the batch index used.
    function _acceptBatch(bytes32 parentHash) internal returns (uint256 batchIndex) {
        batchIndex = rollup.nextBatchIndex();
        RollupStorageLayout.BlockCommitment[] memory batch = _makeBatch(parentHash);
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 0);
    }

    /// @dev Deploy a trivial SP1 verifier stub that never reverts.
    function _deployMockSp1Verifier() internal returns (address) {
        // Minimal contract: verifyProof() does nothing (always succeeds)
        bytes
            memory bytecode = hex"6080604052348015600e575f80fd5b5060b480601a5f395ff3fe6080604052348015600e575f80fd5b50600436106026575f3560e01c80631f7b6d3214602a575b5f80fd5b60306032565b005b56";
        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), "mock sp1 deploy failed");
        return deployed;
    }
}
