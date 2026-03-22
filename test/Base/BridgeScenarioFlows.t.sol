// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {BaseFlowNativeTest} from "./BaseFlowNative.t.sol";
import {BaseFlowERC20Test} from "./BaseFlowERC20.t.sol";

import {NativeGateway} from "../../contracts/gateways/NativeGateway.sol";
import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {IL1FluentBridge} from "../../contracts/interfaces/bridge/IL1FluentBridge.sol";
import {L2BlockHeader} from "../../contracts/interfaces/IRollupTypes.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";

/// @dev L2 execution target that always reverts (unpleasant path: failed message on L2).
contract RevertingMessenger {
    function alwaysRevert() external pure {
        revert("RevertingMessenger");
    }
}

/**
 * @notice Cross-chain scenario tests from TEST_CASES.md (two forks: `L1_RPC_URL` + `L2_RPC_URL`).
 * @dev Use two Anvil instances with **different** `--chain-id` values (e.g. `anvil --chain-id 1 --port 8545`
 *      and `anvil --chain-id 1337 --port 8546`). If both forks share the same chain id as L1,
 *      `receiveMessageWithProof` / `rollbackMessageWithProof` revert with `ForbiddenReceiveRollbackMessage`.
 */
contract BridgeScenarioNativeTest is BaseFlowNativeTest {
    function test_RevertIf_rollbackMessageWithProof_invalidWithdrawalProof() public {
        _selectL1();
        vm.deal(l1Sender, 1 ether);

        uint256 l1OutboundNonce = l1Bridge.getNonce();

        vm.recordLogs();
        vm.prank(l1Sender);
        l1Gateway.sendNativeTokens{value: 1 ether}(l2Recipient);

        address sentFrom;
        address sentTo;
        uint256 sentValue;
        uint256 sentBlockNumber;
        uint256 sentNonce;
        bytes memory sentData;

        {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool found;
            for (uint256 i = 0; i < logs.length; i++) {
                Vm.Log memory entry = logs[i];
                if (entry.emitter != address(l1Bridge)) continue;
                if (entry.topics.length != 3) continue;
                if (entry.topics[0] != SENT_MESSAGE_SIG) continue;

                sentFrom = address(uint160(uint256(entry.topics[1])));
                sentTo = address(uint160(uint256(entry.topics[2])));

                uint256 _sentBlockChainId;
                bytes32 _sentMessageHash;
                (sentValue, _sentBlockChainId, sentBlockNumber, sentNonce, _sentMessageHash, sentData) = abi.decode(
                    entry.data,
                    (uint256, uint256, uint256, uint256, bytes32, bytes)
                );
                found = true;
                break;
            }
            assertTrue(found, "SentMessage log not found for L1->L2 send");
        }

        assertEq(sentNonce, l1OutboundNonce, "sent nonce mismatch");

        _selectL2();
        l2BlockOracle.updateL1BlockNumber(sentBlockNumber + RECEIVE_DEADLINE + 1);

        uint256 l2ChainIdForMessage = l2ChainId;
        bytes32 l2FailedMessageHash = _messageHash(sentFrom, sentTo, sentValue, l2ChainIdForMessage, sentBlockNumber, sentNonce, sentData);

        vm.prank(relayer);
        l2Bridge.receiveMessage(sentFrom, sentTo, sentValue, l2ChainIdForMessage, sentBlockNumber, sentNonce, sentData);

        assertEq(uint256(l2Bridge.getReceivedMessage(l2FailedMessageHash)), uint256(IFluentBridge.MessageStatus.Failed), "L2 should mark failed");

        _selectL1();

        bytes32 wrongWithdrawalRoot = bytes32(uint256(keccak256("not-the-failed-leaf")));
        assertTrue(wrongWithdrawalRoot != l2FailedMessageHash, "precondition: wrong root");

        uint256 batchIndex = l1Rollup.nextBatchIndex();
        L2BlockHeader memory header = L2BlockHeader({
            previousBlockHash: GENESIS_HASH,
            blockHash: keccak256("wrong-withdrawal-block"),
            withdrawalRoot: wrongWithdrawalRoot,
            depositRoot: ZERO_BYTES_HASH,
            depositCount: 0
        });
        L2BlockHeader[] memory headers = new L2BlockHeader[](1);
        headers[0] = header;
        vm.prank(relayer);
        l1Rollup.acceptNextBatch(headers, 1);
        bytes32[] memory blobHashes = new bytes32[](1);
        blobHashes[0] = keccak256(abi.encode("invalid-rollback-blob", batchIndex));
        vm.blobhashes(blobHashes);
        vm.prank(relayer);
        l1Rollup.submitBlobs(batchIndex, 1);
        vm.prank(relayer);
        l1Rollup.preconfirmBatch(address(l1NitroVerifier), batchIndex, DUMMY_SIGNATURE);
        vm.roll(block.number + FINALIZATION_DELAY + 2);
        l1Rollup.finalizeBatches(batchIndex);
        assertTrue(l1Rollup.isBatchFinalized(batchIndex), "batch should be finalized");

        MerkleTree.MerkleProof memory emptyProof = MerkleTree.MerkleProof({nonce: 0, proof: ""});

        vm.prank(relayer);
        vm.expectRevert(IL1FluentBridge.InvalidWithdrawalProof.selector);
        l1Bridge.rollbackMessageWithProof(
            batchIndex,
            header,
            sentFrom,
            sentTo,
            sentValue,
            l2ChainId,
            sentBlockNumber,
            sentNonce,
            sentData,
            emptyProof,
            emptyProof
        );
    }

    /// @notice `receiveMessageWithProof` has no relayer role gate — any account can execute after batch finalization.
    function test_receiveMessageWithProof_succeedsWhenCallerIsNotRelayer() public {
        address anyUser = makeAddr("anyUser");

        _selectL1();
        uint256 l1RecipientBalBefore = l1Recipient.balance;
        vm.deal(address(l1Bridge), 1 ether);
        assertEq(address(l1Bridge).balance, 1 ether, "L1 bridge pre-fund missing");

        _selectL2();
        vm.deal(l2Recipient, 1 ether);

        bytes memory l2ToL1Message = abi.encodeCall(NativeGateway.receiveNativeTokens, (l2Recipient, l1Recipient, 1 ether));

        vm.recordLogs();
        vm.prank(l2Recipient);
        l2Gateway.sendNativeTokens{value: 1 ether}(l1Recipient);
        assertEq(address(l2Bridge).balance, 1 ether, "L2 bridge should lock value");

        bytes32 l1MessageHash;
        uint256 l1ReceiveNonce;
        uint256 l2ChainIdForProof;
        uint256 l2BlockNumberForProof;

        {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool found;
            uint256 sentValue;
            for (uint256 i = 0; i < logs.length; i++) {
                Vm.Log memory entry = logs[i];
                if (entry.emitter != address(l2Bridge)) continue;
                if (entry.topics.length != 3) continue;
                if (entry.topics[0] != SENT_MESSAGE_SIG) continue;

                (sentValue, l2ChainIdForProof, l2BlockNumberForProof, l1ReceiveNonce, l1MessageHash, l2ToL1Message) = abi.decode(
                    entry.data,
                    (uint256, uint256, uint256, uint256, bytes32, bytes)
                );
                assertEq(sentValue, 1 ether, "sent value mismatch");
                found = true;
                break;
            }
            assertTrue(found, "SentMessage log not found for L2->L1 send");
        }

        _finalizeReceiveNativeWithProof(
            l1MessageHash,
            l2ToL1Message,
            l2ChainIdForProof,
            l2BlockNumberForProof,
            l1ReceiveNonce,
            keccak256("l2-native-withdrawal-non-relayer"),
            "native-proof-nr-blob",
            anyUser
        );

        assertEq(uint256(l1Bridge.getReceivedMessage(l1MessageHash)), uint256(IFluentBridge.MessageStatus.Success), "L1 receive status");
        assertEq(l1Recipient.balance - l1RecipientBalBefore, 1 ether, "L1 recipient did not get ETH");
        assertEq(address(l1Bridge).balance, 0, "L1 bridge should have forwarded value");
    }

    /// @notice Outbound `sendMessage` is not sequencer-gated; a normal EOA can enqueue a manual message on L1.
    function test_sendMessage_succeedsFromOrdinaryUserOnL1() public {
        address ordinary = makeAddr("ordinaryUser");
        _selectL1();

        uint256 nonceBefore = l1Bridge.getNonce();
        vm.deal(ordinary, 1 ether);

        vm.prank(ordinary);
        l1Bridge.sendMessage{value: 0.5 ether}(l2Recipient, hex"abcd");

        assertEq(l1Bridge.getNonce(), nonceBefore + 1, "nonce should increment");
        assertEq(address(l1Bridge).balance, 0.5 ether, "bridge should hold locked ETH");
    }

    /// @notice When L2 execution reverts, `receiveMessage` records `Failed` (unpleasant path).
    function test_receiveMessage_marksFailedWhenTargetRevertsOnL2() public {
        _selectL2();
        RevertingMessenger target = new RevertingMessenger();
        bytes memory message = abi.encodeCall(RevertingMessenger.alwaysRevert, ());

        _selectL1();
        vm.recordLogs();
        vm.prank(l1Sender);
        l1Bridge.sendMessage(address(target), message);

        address sentFrom;
        address sentTo;
        uint256 sentValue;
        uint256 sentChainId;
        uint256 sentBlockNumber;
        uint256 sentNonce;
        bytes memory sentData;

        {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool found;
            for (uint256 i = 0; i < logs.length; i++) {
                Vm.Log memory entry = logs[i];
                if (entry.emitter != address(l1Bridge)) continue;
                if (entry.topics.length != 3) continue;
                if (entry.topics[0] != SENT_MESSAGE_SIG) continue;

                sentFrom = address(uint160(uint256(entry.topics[1])));
                sentTo = address(uint160(uint256(entry.topics[2])));

                bytes32 _mh;
                (sentValue, sentChainId, sentBlockNumber, sentNonce, _mh, sentData) = abi.decode(
                    entry.data,
                    (uint256, uint256, uint256, uint256, bytes32, bytes)
                );
                found = true;
                break;
            }
            assertTrue(found, "SentMessage not found");
        }

        bytes32 expectedHash = _messageHash(sentFrom, sentTo, sentValue, sentChainId, sentBlockNumber, sentNonce, sentData);

        _selectL2();
        vm.prank(relayer);
        l2Bridge.receiveMessage(sentFrom, sentTo, sentValue, sentChainId, sentBlockNumber, sentNonce, sentData);

        assertEq(uint256(l2Bridge.getReceivedMessage(expectedHash)), uint256(IFluentBridge.MessageStatus.Failed), "should be Failed after revert");
    }
}

/**
 * @notice ERC20 + access-control scenarios (two forks).
 */
contract BridgeScenarioERC20Test is BaseFlowERC20Test {
    function test_receiveMessageWithProof_succeedsWhenCallerIsNotRelayer() public {
        address anyUser = makeAddr("anyUserErc20");

        _selectL1();
        vm.prank(l1Sender);
        originToken.approve(address(l1Gateway), AMOUNT);
        vm.recordLogs();
        vm.prank(l1Sender);
        l1Gateway.sendTokens(address(originToken), l2Recipient, AMOUNT);

        (
            address from1,
            address to1,
            uint256 value1,
            uint256 chainId1,
            uint256 blockNumber1,
            uint256 nonce1,
            ,
            bytes memory data1
        ) = _decodeBridgeSentMessage(vm.getRecordedLogs(), address(l1Bridge));
        address peggedOnL2 = l1Gateway.computeOtherSidePeggedTokenAddress(address(l2Gateway), address(originToken));

        _selectL2();
        vm.prank(relayer);
        l2Bridge.receiveMessage(from1, to1, value1, chainId1, blockNumber1, nonce1, data1);
        assertEq(IERC20(peggedOnL2).balanceOf(l2Recipient), AMOUNT, "pegged not minted");

        vm.prank(l2Recipient);
        IERC20(peggedOnL2).approve(address(l2Gateway), AMOUNT / 2);
        vm.recordLogs();
        vm.prank(l2Recipient);
        l2Gateway.sendTokens(peggedOnL2, l1Recipient, AMOUNT / 2);

        (
            address from2,
            address to2,
            uint256 value2,
            uint256 chainId2,
            uint256 blockNumber2,
            uint256 nonce2,
            bytes32 messageHash,
            bytes memory data2
        ) = _decodeBridgeSentMessage(vm.getRecordedLogs(), address(l2Bridge));

        _selectL1();
        uint256 originBefore = originToken.balanceOf(l1Recipient);

        _receiveErc20WithProof(messageHash, from2, to2, value2, chainId2, blockNumber2, nonce2, data2, anyUser);

        assertEq(uint256(l1Bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success), "receive status");
        assertEq(originToken.balanceOf(l1Recipient) - originBefore, AMOUNT / 2, "origin not unlocked");
    }

    /// @notice L1 -> L2 delivery requires `RELAYER_ROLE`; without it the user cannot complete receive on L2.
    function test_RevertIf_receiveMessage_callerNotRelayerOnL2() public {
        address notRelayer = makeAddr("notRelayer");

        _selectL1();
        vm.prank(l1Sender);
        originToken.approve(address(l1Gateway), AMOUNT);
        vm.recordLogs();
        vm.prank(l1Sender);
        l1Gateway.sendTokens(address(originToken), l2Recipient, AMOUNT);

        (
            address from1,
            address to1,
            uint256 value1,
            uint256 chainId1,
            uint256 blockNumber1,
            uint256 nonce1,
            ,
            bytes memory data1
        ) = _decodeBridgeSentMessage(vm.getRecordedLogs(), address(l1Bridge));

        _selectL2();
        vm.prank(notRelayer);
        vm.expectRevert();
        l2Bridge.receiveMessage(from1, to1, value1, chainId1, blockNumber1, nonce1, data1);
    }
}
