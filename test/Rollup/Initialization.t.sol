// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {RollupStorageLayout} from "../../contracts/rollup/RollupStorageLayout.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {VerifierMock} from "../../contracts/mocks/VerifierMock.sol";
import {RollupBase} from "./Base.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract RollupInitializationTest is RollupBase {
    function setUp() public {
        _deployMockRollup({
            batchSize_: 2,
            challengeDepositAmount_: 10000,
            challengeBlockCount_: 1,
            approveBlockCount_: 1,
            acceptDepositDeadline_: 10,
            incentiveFee_: 0
        });
    }

    function test_initialize_setsInitialState() public view {
        assertEq(rollup.bridge(), address(bridge), "bridge mismatch");
        assertEq(rollup.programVKey(), MOCK_VK_KEY, "vk mismatch");
        assertEq(rollup.batchSize(), 2, "batch size mismatch");
        assertEq(rollup.nextBatchIndex(), 1, "nextBatchIndex mismatch");
        assertEq(rollup.lastBlockHashInBatch(0), MOCK_GENESIS_HASH, "genesis hash mismatch");
    }

    function test_initialize_revertsWhenAdminIsZero() public {
        VerifierMock verifier = new VerifierMock();
        Rollup rollupImpl = new Rollup();
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroAddressNotAllowed.selector, "admin"));
        RollupStorageLayout.InitConfiguration memory params = RollupStorageLayout.InitConfiguration({
            admin: address(0),
            pauser: address(0),
            sequencer: SEQUENCER,
            challengeDepositAmount: 10000,
            challengeBlockCount: 1,
            approveBlockCount: 1,
            verifier: address(verifier),
            programVKey: MOCK_VK_KEY,
            genesisHash: MOCK_GENESIS_HASH,
            bridge: address(0x1),
            batchSize: 2,
            acceptDepositDeadline: 10,
            incentiveFee: 0,
            challenger: address(0),
            prover: address(0)
        });
        new ERC1967Proxy(address(rollupImpl), abi.encodeCall(Rollup.initialize, (abi.encode(params))));
    }

    function test_initialize_revertsWhenSequencerIsZero() public {
        VerifierMock verifier = new VerifierMock();
        Rollup rollupImpl = new Rollup();
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroAddressNotAllowed.selector, "sequencer"));
        RollupStorageLayout.InitConfiguration memory params = RollupStorageLayout.InitConfiguration({
            admin: address(this),
            pauser: address(0),
            sequencer: address(0),
            challengeDepositAmount: 10000,
            challengeBlockCount: 1,
            approveBlockCount: 1,
            verifier: address(verifier),
            programVKey: MOCK_VK_KEY,
            genesisHash: MOCK_GENESIS_HASH,
            bridge: address(0x1),
            batchSize: 2,
            acceptDepositDeadline: 10,
            incentiveFee: 0,
            challenger: address(0),
            prover: address(0)
        });
        new ERC1967Proxy(address(rollupImpl), abi.encodeCall(Rollup.initialize, (abi.encode(params))));
    }

    function test_initialize_revertsWhenVerifierIsZero() public {
        Rollup rollupImpl = new Rollup();
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroAddressNotAllowed.selector, "verifier"));
        RollupStorageLayout.InitConfiguration memory params = RollupStorageLayout.InitConfiguration({
            admin: address(this),
            pauser: address(0),
            sequencer: SEQUENCER,
            challengeDepositAmount: 10000,
            challengeBlockCount: 1,
            approveBlockCount: 1,
            verifier: address(0),
            programVKey: MOCK_VK_KEY,
            genesisHash: MOCK_GENESIS_HASH,
            bridge: address(0x1),
            batchSize: 2,
            acceptDepositDeadline: 10,
            incentiveFee: 0,
            challenger: address(0),
            prover: address(0)
        });
        new ERC1967Proxy(address(rollupImpl), abi.encodeCall(Rollup.initialize, (abi.encode(params))));
    }

    function test_initialize_revertsWhenProgramVKeyIsZero() public {
        VerifierMock verifier = new VerifierMock();
        Rollup rollupImpl = new Rollup();
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroValueNotAllowed.selector, "programVKey"));
        RollupStorageLayout.InitConfiguration memory params = RollupStorageLayout.InitConfiguration({
            admin: address(this),
            pauser: address(0),
            sequencer: SEQUENCER,
            challengeDepositAmount: 10000,
            challengeBlockCount: 1,
            approveBlockCount: 1,
            verifier: address(verifier),
            programVKey: bytes32(0),
            genesisHash: MOCK_GENESIS_HASH,
            bridge: address(0x1),
            batchSize: 2,
            acceptDepositDeadline: 10,
            incentiveFee: 0,
            challenger: address(0),
            prover: address(0)
        });
        new ERC1967Proxy(address(rollupImpl), abi.encodeCall(Rollup.initialize, (abi.encode(params))));
    }

    function test_initialize_revertsWhenGenesisHashIsZero() public {
        VerifierMock verifier = new VerifierMock();
        Rollup rollupImpl = new Rollup();
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroValueNotAllowed.selector, "genesisHash"));
        RollupStorageLayout.InitConfiguration memory params = RollupStorageLayout.InitConfiguration({
            admin: address(this),
            pauser: address(0),
            sequencer: SEQUENCER,
            challengeDepositAmount: 10000,
            challengeBlockCount: 1,
            approveBlockCount: 1,
            verifier: address(verifier),
            programVKey: MOCK_VK_KEY,
            genesisHash: bytes32(0),
            bridge: address(0x1),
            batchSize: 2,
            acceptDepositDeadline: 10,
            incentiveFee: 0,
            challenger: address(0),
            prover: address(0)
        });
        new ERC1967Proxy(address(rollupImpl), abi.encodeCall(Rollup.initialize, (abi.encode(params))));
    }

    function test_initialize_revertsWhenBatchSizeIsZero() public {
        VerifierMock verifier = new VerifierMock();
        Rollup rollupImpl = new Rollup();
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroValueNotAllowed.selector, "batchSize"));
        RollupStorageLayout.InitConfiguration memory params = RollupStorageLayout.InitConfiguration({
            admin: address(this),
            pauser: address(0),
            sequencer: SEQUENCER,
            challengeDepositAmount: 10000,
            challengeBlockCount: 1,
            approveBlockCount: 1,
            verifier: address(verifier),
            programVKey: MOCK_VK_KEY,
            genesisHash: MOCK_GENESIS_HASH,
            bridge: address(0x1),
            batchSize: 0,
            acceptDepositDeadline: 10,
            incentiveFee: 0,
            challenger: address(0),
            prover: address(0)
        });
        new ERC1967Proxy(address(rollupImpl), abi.encodeCall(Rollup.initialize, (abi.encode(params))));
    }
}
