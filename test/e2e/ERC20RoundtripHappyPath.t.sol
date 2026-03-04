// SPDX-License-Identifier: MIT
// E2E purpose: canonical ERC20 bridge roundtrip on dual-fork setup.
// Flow direction: L2 -> L1 (proof path), then L1 -> L2 (bridge authority path).
pragma solidity ^0.8.30;

import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {RollupStorageLayout} from "../../contracts/rollup/RollupStorage.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {IFluentBridge} from "../../contracts/interfaces/IFluentBridge.sol";
import {BaseDualFork, VmFork} from "./BaseDualFork.t.sol";

contract ERC20RoundtripHappyPathTest is BaseDualFork {
    uint256 internal constant TRANSFER_AMOUNT = 100 ether;

    function setUp() public {
        _setUpDualFork();
    }

    function test_comparePeggedTokenAddresses_matchesOtherSideComputation() public {
        _switchToL2();
        _assertOnL2();
        address peggedOnL2 = l2.gateway.computePeggedTokenAddress(address(l2.originToken));

        _switchToL1();
        _assertOnL1();
        address peggedFromL1View = l1.gateway.computeOtherSidePeggedTokenAddress(address(l2.originToken));

        assertEq(peggedOnL2, peggedFromL1View, "pegged-token address parity mismatch across gateways");
    }

    function test_e2e_erc20Roundtrip_happyPath_dualFork_daOn() public {
        // Step 1: L2 user sends origin tokens to L1 recipient through L2 gateway.
        _switchToL2();
        _assertOnL2();
        uint256 userAInitialBalance = l2.originToken.balanceOf(USER_A);
        assertEq(userAInitialBalance, INITIAL_SUPPLY, "unexpected initial L2 balance");

        vm.startPrank(USER_A);
        l2.originToken.approve(address(l2.gateway), TRANSFER_AMOUNT);
        vm.recordLogs();
        l2.gateway.sendTokens(address(l2.originToken), USER_B, TRANSFER_AMOUNT);
        VmFork.Log[] memory l2Logs = vm.getRecordedLogs();
        vm.stopPrank();

        SentMessageData memory l2ToL1 = _findSentMessage(l2Logs, address(l2.bridge));
        assertEq(l2ToL1.sender, address(l2.gateway), "wrong L2 sender");
        assertEq(l2ToL1.to, address(l1.gateway), "wrong L2 destination");
        assertEq(
            l2.originToken.balanceOf(USER_A),
            userAInitialBalance - TRANSFER_AMOUNT,
            "L2 user balance not reduced after send"
        );
        assertEq(l2.originToken.balanceOf(address(l2.gateway)), TRANSFER_AMOUNT, "L2 gateway should hold locked tokens");

        // Step 2: L1 sequencer accepts batch with withdrawal root and DA check.
        _switchToL1();
        _assertOnL1();
        bytes32 batch1BlockHash = keccak256("L1-BATCH-1");
        RollupStorageLayout.BlockCommitment memory batch1Commitment =
            _buildCommitment(MOCK_GENESIS_HASH, batch1BlockHash, l2ToL1.messageHash, ZERO_HASH);
        _acceptSingleCommitmentBatchL1(1, batch1Commitment, new RollupStorageLayout.DepositsInBlock[](0));

        // Step 3: L1 bridge processes proven withdrawal and mints pegged token.
        vm.roll(block.number + 1);
        MerkleTree.MerkleProof memory proof = _singleLeafProof();
        l1.bridge.receiveMessageWithProof(
            1,
            batch1Commitment,
            l2ToL1.sender,
            payable(l2ToL1.to),
            l2ToL1.value,
            l2ToL1.chainId,
            l2ToL1.blockNumber,
            l2ToL1.nonce,
            l2ToL1.data,
            proof,
            proof
        );

        address l1PeggedTokenAddress = l1.gateway.computePeggedTokenAddress(address(l2.originToken));
        ERC20PeggedToken l1PeggedToken = ERC20PeggedToken(l1PeggedTokenAddress);
        assertEq(l1PeggedToken.balanceOf(USER_B), TRANSFER_AMOUNT, "L1 pegged mint failed");
        assertEq(
            uint256(l1.bridge.receivedMessage(l2ToL1.messageHash)),
            uint256(IFluentBridge.MessageStatus.Success),
            "L1 message status should be success"
        );

        // Step 4: L1 user sends pegged token back to L2.
        vm.startPrank(USER_B);
        l1PeggedToken.approve(address(l1.gateway), TRANSFER_AMOUNT);
        vm.recordLogs();
        l1.gateway.sendTokens(l1PeggedTokenAddress, USER_A, TRANSFER_AMOUNT);
        VmFork.Log[] memory l1Logs = vm.getRecordedLogs();
        vm.stopPrank();

        SentMessageData memory l1ToL2 = _findSentMessage(l1Logs, address(l1.bridge));
        assertEq(l1ToL2.sender, address(l1.gateway), "wrong L1 sender");
        assertEq(l1ToL2.to, address(l2.gateway), "wrong L1 destination");
        assertEq(l1.bridge.getQueueSize(), 1, "L1 queue must contain one deposit");

        // Step 5: L2 bridge authority executes return message on destination gateway.
        _switchToL2();
        _assertOnL2();
        vm.prank(BRIDGE_AUTHORITY);
        l2.bridge.receiveMessage(
            l1ToL2.sender, l1ToL2.to, l1ToL2.value, l1ToL2.chainId, l1ToL2.blockNumber, l1ToL2.nonce, l1ToL2.data
        );

        assertEq(
            uint256(l2.bridge.receivedMessage(l1ToL2.messageHash)),
            uint256(IFluentBridge.MessageStatus.Success),
            "L2 message status should be success"
        );
        assertEq(
            l2.originToken.balanceOf(USER_A), userAInitialBalance, "L2 user balance should be restored after roundtrip"
        );
        assertEq(l2.originToken.balanceOf(address(l2.gateway)), 0, "L2 gateway should release locked tokens");

        // Step 6: L1 sequencer accepts deposit batch and consumes L1 bridge queue.
        _switchToL1();
        _assertOnL1();
        bytes32 batch2BlockHash = keccak256("L1-BATCH-2");
        bytes32 depositHash = keccak256(abi.encodePacked(l1ToL2.messageHash));
        RollupStorageLayout.BlockCommitment memory batch2Commitment =
            _buildCommitment(batch1Commitment.blockHash, batch2BlockHash, ZERO_HASH, depositHash);

        RollupStorageLayout.DepositsInBlock[] memory deposits = new RollupStorageLayout.DepositsInBlock[](1);
        deposits[0] = RollupStorageLayout.DepositsInBlock({blockHash: batch2BlockHash, depositCount: 1});
        _acceptSingleCommitmentBatchL1(2, batch2Commitment, deposits);

        // Step 7: Verify final invariants for balances, queue state, and message status.
        assertEq(l1.rollup.nextBatchIndex(), 3, "unexpected nextBatchIndex");
        assertEq(l1.bridge.getQueueSize(), 0, "L1 queue should be consumed after deposit validation");
        assertEq(l1PeggedToken.balanceOf(USER_B), 0, "L1 pegged token should be burned after return transfer");

        _switchToL2();
        _assertOnL2();
        assertEq(
            uint256(l2.bridge.receivedMessage(l1ToL2.messageHash)),
            uint256(IFluentBridge.MessageStatus.Success),
            "L2 final message status mismatch"
        );
    }

    function test_acceptBatch_reverts_whenDaBlobHashMissing() public {
        // Step 1: Build a valid batch but do not attach blob data.
        _switchToL1();
        _assertOnL1();

        RollupStorageLayout.BlockCommitment[] memory batch = new RollupStorageLayout.BlockCommitment[](1);
        batch[0] = _buildCommitment(MOCK_GENESIS_HASH, keccak256("DA-MISMATCH-BLOCK"), ZERO_HASH, ZERO_HASH);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroValueNotAllowed.selector, "blobHash"));
        vm.prank(SEQUENCER);
        l1.rollup.acceptNextBatch(batch, new RollupStorageLayout.DepositsInBlock[](0), 1);
    }
}
