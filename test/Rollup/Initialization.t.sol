// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Base.t.sol";

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

    function test_constructor_setsInitialState() public view {
        assertEq(rollup.sequencer(), SEQUENCER, "sequencer mismatch");
        assertEq(rollup.bridge(), address(bridge), "bridge mismatch");
        assertEq(rollup.programVKey(), MOCK_VK_KEY, "vk mismatch");
        assertEq(rollup.batchSize(), 2, "batch size mismatch");
        assertEq(rollup.nextBatchIndex(), 1, "nextBatchIndex mismatch");
        assertEq(
            rollup.lastBlockHashInBatch(0),
            MOCK_GENESIS_HASH,
            "genesis hash mismatch"
        );
    }

    function test_constructor_revertsWhenSequencerIsZero() public {
        VerifierMock verifier = new VerifierMock();
        vm.expectRevert(
            abi.encodeWithSelector(
                Rollup.ZeroAddressNotAllowed.selector,
                "sequencer"
            )
        );
        new Rollup(
            address(0),
            10000,
            1,
            1,
            address(verifier),
            MOCK_VK_KEY,
            MOCK_GENESIS_HASH,
            address(0x1),
            2,
            10,
            0
        );
    }

    function test_constructor_revertsWhenVerifierIsZero() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Rollup.ZeroAddressNotAllowed.selector,
                "verifier"
            )
        );
        new Rollup(
            SEQUENCER,
            10000,
            1,
            1,
            address(0),
            MOCK_VK_KEY,
            MOCK_GENESIS_HASH,
            address(0x1),
            2,
            10,
            0
        );
    }

    function test_constructor_revertsWhenProgramVKeyIsZero() public {
        VerifierMock verifier = new VerifierMock();
        vm.expectRevert(
            abi.encodeWithSelector(
                Rollup.ZeroValueNotAllowed.selector,
                "programVKey"
            )
        );
        new Rollup(
            SEQUENCER,
            10000,
            1,
            1,
            address(verifier),
            bytes32(0),
            MOCK_GENESIS_HASH,
            address(0x1),
            2,
            10,
            0
        );
    }

    function test_constructor_revertsWhenGenesisHashIsZero() public {
        VerifierMock verifier = new VerifierMock();
        vm.expectRevert(
            abi.encodeWithSelector(
                Rollup.ZeroValueNotAllowed.selector,
                "genesisHash"
            )
        );
        new Rollup(
            SEQUENCER,
            10000,
            1,
            1,
            address(verifier),
            MOCK_VK_KEY,
            bytes32(0),
            address(0x1),
            2,
            10,
            0
        );
    }

    function test_constructor_revertsWhenBatchSizeIsZero() public {
        VerifierMock verifier = new VerifierMock();
        vm.expectRevert(
            abi.encodeWithSelector(
                Rollup.ZeroValueNotAllowed.selector,
                "batchSize"
            )
        );
        new Rollup(
            SEQUENCER,
            10000,
            1,
            1,
            address(verifier),
            MOCK_VK_KEY,
            MOCK_GENESIS_HASH,
            address(0x1),
            0,
            10,
            0
        );
    }
}
