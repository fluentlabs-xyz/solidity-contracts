// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {FluentBridgeStorageLayout} from "../../contracts/bridge/FluentBridgeStorageLayout.sol";

import {L1BlockOracle} from "../../contracts/oracles/L1BlockOracle.sol";
import {L1GasOracle} from "../../contracts/oracles/L1GasOracle.sol";
import {NativeGateway} from "../../contracts/gateways/NativeGateway.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";

import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {InitConfiguration, L2BlockHeader} from "../../contracts/interfaces/IRollupTypes.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";

import {WithdrawalMerkle} from "../helpers/WithdrawalMerkle.sol";
import {MockNitroVerifier} from "../mocks/MockNitroVerifier.sol";
import {MockSp1Verifier} from "../mocks/MockSp1Verifier.sol";

contract BaseFlowNativeTest is Test {
    uint256 internal constant RECEIVE_DEADLINE = 100;
    bytes32 internal constant ZERO_BYTES_HASH = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    bytes32 internal constant GENESIS_HASH = keccak256("genesis");
    bytes32 internal constant PROGRAM_VKEY = keccak256("vkey");
    bytes internal constant DUMMY_SIGNATURE = abi.encodePacked(keccak256("r"), keccak256("s"), uint8(27));
    uint256 internal constant FINALIZATION_DELAY = 1;
    uint256 internal constant MAX_FORCE_REVERT_BATCH_SIZE = 10;
    bytes32 internal constant SENT_MESSAGE_SIG = keccak256("SentMessage(address,address,uint256,uint256,uint256,uint256,bytes32,bytes)");

    // Fork ids
    uint256 internal l1ForkId;
    uint256 internal l2ForkId;
    uint256 internal l1ChainId;
    uint256 internal l2ChainId;

    // Actors
    address internal admin;
    address internal relayer;
    address internal l1Sender;
    address internal l2Recipient;
    address internal l1Recipient;

    // L1 contracts
    L1FluentBridge internal l1Bridge;
    NativeGateway internal l1Gateway;
    Rollup internal l1Rollup;
    MockNitroVerifier internal l1NitroVerifier;

    // L2 contracts
    L2FluentBridge internal l2Bridge;
    NativeGateway internal l2Gateway;
    L1BlockOracle internal l2BlockOracle;
    L1GasOracle internal l2GasOracle;

    function setUp() public {
        admin = address(this);
        relayer = makeAddr("relayer");
        l1Sender = makeAddr("l1Sender");
        l2Recipient = makeAddr("l2Recipient");
        l1Recipient = makeAddr("l1Recipient");

        string memory l1RpcUrl = vm.envOr("L1_RPC_URL", string(""));
        string memory l2RpcUrl = vm.envOr("L2_RPC_URL", string(""));
        if (bytes(l1RpcUrl).length == 0 || bytes(l2RpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        l1ForkId = vm.createFork(l1RpcUrl);
        l2ForkId = vm.createFork(l2RpcUrl);

        _selectL1();
        if (block.number < 1) vm.roll(1);
        l1ChainId = block.chainid;
        _selectL2();
        if (block.number < 1) vm.roll(1);
        l2ChainId = block.chainid;

        _deployOnL1();
        _deployOnL2();
        _linkCrossChain();
    }

    function _selectL1() internal {
        vm.selectFork(l1ForkId);
    }

    function _selectL2() internal {
        vm.selectFork(l2ForkId);
    }

    function _deployOnL1() internal {
        _selectL1();

        // Deploy real Rollup used for L2->L1 proof-based withdrawals.
        l1NitroVerifier = new MockNitroVerifier();
        MockSp1Verifier sp1 = new MockSp1Verifier();

        InitConfiguration memory cfg;
        cfg.admin = admin;
        cfg.emergency = admin;
        cfg.sequencer = relayer;
        cfg.challenger = address(0);
        cfg.prover = address(0);
        cfg.preconfirmationRole = relayer;
        cfg.sp1Verifier = address(sp1);
        cfg.nitroVerifier = address(l1NitroVerifier);
        cfg.bridge = address(0xB1); // not used because we set depositRoot == ZERO_BYTES_HASH in the test
        cfg.programVKey = PROGRAM_VKEY;
        cfg.genesisHash = GENESIS_HASH;
        cfg.challengeDepositAmount = 1 ether;
        cfg.challengeWindow = 0;
        cfg.finalizationDelay = FINALIZATION_DELAY;
        cfg.acceptDepositDeadline = 1000;
        cfg.incentiveFee = 0;
        cfg.submitBlobsWindow = 0;
        cfg.preconfirmWindow = 1;
        cfg.maxForceRevertBatchSize = MAX_FORCE_REVERT_BATCH_SIZE;

        Rollup rollupImpl = new Rollup();
        ERC1967Proxy rollupProxy = new ERC1967Proxy(address(rollupImpl), abi.encodeCall(Rollup.initialize, (abi.encode(cfg))));
        l1Rollup = Rollup(payable(address(rollupProxy)));

        // Deploy L1 bridge (UUPS proxy)
        FluentBridgeStorageLayout.InitConfiguration memory params = FluentBridgeStorageLayout.InitConfiguration({
            adminRole: admin,
            pauserRole: admin,
            relayerRole: relayer,
            otherBridge: address(0xB1) // patched after L2 is deployed
        });

        L1FluentBridge bridgeImpl = new L1FluentBridge();
        ERC1967Proxy bridgeProxy = new ERC1967Proxy(
            address(bridgeImpl),
            abi.encodeCall(L1FluentBridge.initialize, (abi.encode(params), address(l1Rollup)))
        );
        l1Bridge = L1FluentBridge(payable(address(bridgeProxy)));

        // Deploy NativeGateway
        NativeGateway gatewayImpl = new NativeGateway();
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(address(gatewayImpl), abi.encodeCall(NativeGateway.initialize, (admin, address(l1Bridge))));
        l1Gateway = NativeGateway(payable(address(gatewayProxy)));
    }

    function _deployOnL2() internal {
        _selectL2();

        // Oracle is used for L2 deadline/rollback checks. We keep it at the default (0),
        // so our test messages will not trip the "deadline exceeded" branch.
        l2BlockOracle = new L1BlockOracle(address(this));
        l2GasOracle = new L1GasOracle(relayer);

        FluentBridgeStorageLayout.InitConfiguration memory params = FluentBridgeStorageLayout.InitConfiguration({
            adminRole: admin,
            pauserRole: admin,
            relayerRole: relayer,
            otherBridge: address(0xB2)
        });

        // Deploy L2 bridge (UUPS proxy)
        L2FluentBridge bridgeImpl = new L2FluentBridge();
        ERC1967Proxy bridgeProxy = new ERC1967Proxy(
            address(bridgeImpl),
            abi.encodeCall(
                L2FluentBridge.initialize,
                (abi.encode(params), RECEIVE_DEADLINE, address(l2BlockOracle), address(l2GasOracle), 0, 0, 0, makeAddr("feeTreasury"))
            )
        );
        l2Bridge = L2FluentBridge(payable(address(bridgeProxy)));

        // Deploy NativeGateway
        NativeGateway gatewayImpl = new NativeGateway();
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(address(gatewayImpl), abi.encodeCall(NativeGateway.initialize, (admin, address(l2Bridge))));
        l2Gateway = NativeGateway(payable(address(gatewayProxy)));
    }

    function _linkCrossChain() internal {
        // Link L1 -> L2
        _selectL1();
        l1Bridge.setOtherBridge(address(l2Bridge));
        l1Gateway.setOtherSideGateway(address(l2Gateway));

        // Link L2 -> L1
        _selectL2();
        l2Bridge.setOtherBridge(address(l1Bridge));
        l2Gateway.setOtherSideGateway(address(l1Gateway));
    }

    function _messageHash(
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 nonce,
        bytes memory message
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(from, to, value, chainId, blockNumber, nonce, message));
    }

    /// @dev Finalize batch with `withdrawalRoot` built only from the real L2→L1 `SentMessage` hash, then proof-receive.
    function _finalizeReceiveNativeWithProof(
        bytes32 l1MessageHash,
        bytes memory l2ToL1Message,
        uint256 l2ChainIdForProof,
        uint256 l2BlockNumberForProof,
        uint256 l1ReceiveNonce,
        bytes32 l2BlockHash,
        string memory blobLabel,
        address proofCaller
    ) internal {
        bytes32[] memory wl = WithdrawalMerkle.leavesSingleton(l1MessageHash);
        (uint256 batchIndex, L2BlockHeader memory header) = _finalizeL1SingleBlockBatch(wl, l2BlockHash, blobLabel);
        ReceiveMessageWithProofArgs memory callArgs;
        callArgs.batchIndex = batchIndex;
        callArgs.header = header;
        callArgs.l2Gateway = address(l2Gateway);
        callArgs.l1Gateway = payable(address(l1Gateway));
        callArgs.value = 1 ether;
        callArgs.l2ChainId = l2ChainIdForProof;
        callArgs.l2BlockNumber = l2BlockNumberForProof;
        callArgs.l1ReceiveNonce = l1ReceiveNonce;
        callArgs.message = l2ToL1Message;
        callArgs.withdrawalProof = WithdrawalMerkle.proofForLeaf(wl, 0);
        callArgs.blockProof = MerkleTree.MerkleProof({nonce: 0, proof: ""});
        _receiveMessageWithProofNative(l1Bridge, proofCaller, callArgs);
    }

    function test_sendNativeTokens_roundtripL1ToL2AndBack() public {
        // ============ Step 1: L1 sender sends native to L2 recipient ============
        _selectL1();
        vm.deal(l1Sender, 1 ether);

        uint256 l1BlockNumber = block.number < 1 ? 1 : block.number;
        uint256 l1OutboundNonce = l1Bridge.getNonce();

        bytes memory l1ToL2Message = abi.encodeCall(NativeGateway.receiveNativeTokens, (l1Sender, l2Recipient, 1 ether));

        vm.prank(l1Sender);
        l1Gateway.sendNativeTokens{value: 1 ether}(l2Recipient);

        assertEq(address(l1Bridge).balance, 1 ether, "L1 bridge should lock funds");
        assertEq(address(l2Bridge).balance, 0, "L2 bridge should start empty");

        // ============ Step 2: Relayer executes on L2 ============
        _selectL2();
        uint256 l2PreRecipientBal = l2Recipient.balance;

        // Simulate "underhood mint/unlock" into the L2 bridge so it can forward value.
        vm.deal(address(l2Bridge), 1 ether);
        assertEq(address(l2Bridge).balance, 1 ether, "L2 bridge pre-fund missing");

        uint256 l2ReceiveNonce = l1OutboundNonce;
        assertEq(l2Bridge.getReceivedNonce(), l2ReceiveNonce, "unexpected L2 received nonce");
        bytes32 l2MessageHash = _messageHash(
            address(l1Gateway),
            address(l2Gateway),
            1 ether,
            l1ChainId,
            l1BlockNumber,
            l2ReceiveNonce,
            l1ToL2Message
        );

        vm.prank(relayer);
        l2Bridge.receiveMessage(address(l1Gateway), address(l2Gateway), 1 ether, l1ChainId, l1BlockNumber, l2ReceiveNonce, l1ToL2Message);

        assertEq(uint256(l2Bridge.getReceivedMessage(l2MessageHash)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(l2Recipient.balance - l2PreRecipientBal, 1 ether, "L2 recipient didn't get ETH");
        assertEq(address(l2Bridge).balance, 0, "L2 bridge should have forwarded all value");

        // ============ Step 3: L2 recipient sends back to L1 recipient ============
        uint256 l2ChainIdForProof;
        uint256 l2BlockNumberForProof;
        uint256 l1ReceiveNonce;
        bytes32 l1MessageHash;
        uint256 l2OutboundNonce = l2Bridge.getNonce();

        bytes memory l2ToL1Message = abi.encodeCall(NativeGateway.receiveNativeTokens, (l2Recipient, l1Recipient, 1 ether));

        assertEq(l2Bridge.getNonce(), l2OutboundNonce, "sanity");
        vm.recordLogs();
        vm.prank(l2Recipient);
        l2Gateway.sendNativeTokens{value: 1 ether}(l1Recipient);

        assertEq(address(l2Bridge).balance, 1 ether, "L2 bridge should lock on return send");

        // Extract message metadata from SentMessage emitted by l2Bridge.
        {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool found;
            for (uint256 i = 0; i < logs.length; i++) {
                Vm.Log memory entry = logs[i];
                if (entry.emitter != address(l2Bridge)) continue;
                if (entry.topics.length != 3) continue;
                if (entry.topics[0] != SENT_MESSAGE_SIG) continue;

                // topics[1] = indexed sender, topics[2] = indexed to
                uint256 sentValue;
                uint256 sentChainId;
                uint256 sentBlockNumber;
                uint256 sentNonce;
                bytes32 sentMessageHash;
                bytes memory sentData;
                (sentValue, sentChainId, sentBlockNumber, sentNonce, sentMessageHash, sentData) = abi.decode(
                    entry.data,
                    (uint256, uint256, uint256, uint256, bytes32, bytes)
                );

                assertEq(sentValue, 1 ether, "return send value mismatch");
                l2ChainIdForProof = sentChainId;
                l2BlockNumberForProof = sentBlockNumber;
                l1ReceiveNonce = sentNonce;
                l1MessageHash = sentMessageHash;
                assertEq(sentNonce, l2OutboundNonce, "return send nonce mismatch");
                found = true;
                break;
            }
            assertTrue(found, "SentMessage log not found for L2->L1 return");
        }


        // ============ Step 4: Relayer executes return on L1 ============
        _selectL1();
        uint256 l1PreRecipientBal = l1Recipient.balance;
        assertEq(address(l1Bridge).balance, 1 ether, "L1 bridge should have funds to unlock");

        _finalizeReceiveNativeWithProof(
            l1MessageHash,
            l2ToL1Message,
            l2ChainIdForProof,
            l2BlockNumberForProof,
            l1ReceiveNonce,
            keccak256("l2-withdrawal-block"),
            "native-flow-blob",
            relayer
        );

        assertEq(uint256(l1Bridge.getReceivedMessage(l1MessageHash)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(l1Recipient.balance - l1PreRecipientBal, 1 ether, "L1 recipient didn't get ETH back");
        assertEq(address(l1Bridge).balance, 0, "L1 bridge should have forwarded all locked value");
    }

    function test_rollbackMessageWithProof_deadlineRefundsOnL1() public {
        // ============ Step 1: L1 sender sends native to L2 recipient ============
        _selectL1();
        vm.deal(l1Sender, 1 ether);

        uint256 l1OutboundNonce = l1Bridge.getNonce();
        bytes memory l1ToL2Message = abi.encodeCall(NativeGateway.receiveNativeTokens, (l1Sender, l2Recipient, 1 ether));

        vm.recordLogs();
        vm.prank(l1Sender);
        l1Gateway.sendNativeTokens{value: 1 ether}(l2Recipient);

        assertEq(address(l1Bridge).balance, 1 ether, "L1 bridge should lock funds");

        // Extract the exact SentMessage fields emitted by l1Bridge.
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

        assertEq(sentValue, 1 ether, "sent value mismatch");
        assertEq(sentNonce, l1OutboundNonce, "sent nonce mismatch");
        assertEq(sentData, l1ToL2Message, "sent message payload mismatch");
        assertEq(sentFrom, address(l1Gateway), "unexpected sentFrom");
        assertEq(sentTo, address(l2Gateway), "unexpected sentTo");


        // ============ Step 2: Relayer tries receiveMessage on L2, but deadline expires ============
        _selectL2();

        // Make L2 treat the message as timed-out (eligible for rollback).
        l2BlockOracle.updateL1BlockNumber(sentBlockNumber + RECEIVE_DEADLINE + 1);

        // We pass L2 chainid as the `chainId` field in the hashed message, because
        // L1FluentBridge.rollbackMessageWithProof forbids calling when `chainId == block.chainid` on L1.
        uint256 l2ChainIdForMessage = l2ChainId;
        uint256 l2ReceiveNonce = l2Bridge.getReceivedNonce();
        assertEq(l2ReceiveNonce, sentNonce, "nonce mismatch");

        bytes32 l2FailedMessageHash = _messageHash(sentFrom, sentTo, sentValue, l2ChainIdForMessage, sentBlockNumber, sentNonce, sentData);

        vm.prank(relayer);
        l2Bridge.receiveMessage(sentFrom, sentTo, sentValue, l2ChainIdForMessage, sentBlockNumber, sentNonce, sentData);

        assertEq(uint256(l2Bridge.getReceivedMessage(l2FailedMessageHash)), uint256(IFluentBridge.MessageStatus.Failed));

        // ============ Step 3: Finalize rollup batch on L1 containing the rollback withdrawalRoot ============
        _selectL1();

        bytes32[] memory withdrawalLeaves = WithdrawalMerkle.leavesSingleton(l2FailedMessageHash);

        (uint256 batchIndex, L2BlockHeader memory header) = _finalizeL1SingleBlockBatch(
            withdrawalLeaves,
            keccak256("l2-rollback-withdrawal-block"),
            "native-rollback-blob"
        );

        // ============ Step 4: Relayer executes rollback on L1 ============
        uint256 l1GatewayBalBefore = address(l1Gateway).balance;
        assertEq(address(l1Bridge).balance, 1 ether, "precondition: bridge should still hold funds");

        RollbackMessageWithProofArgs memory rollbackArgs;
        rollbackArgs.batchIndex = batchIndex;
        rollbackArgs.header = header;
        rollbackArgs.from = sentFrom;
        rollbackArgs.to = payable(sentTo);
        rollbackArgs.value = sentValue;
        rollbackArgs.l2ChainId = l2ChainId;
        rollbackArgs.blockNumber = sentBlockNumber;
        rollbackArgs.messageNonce = sentNonce;
        rollbackArgs.message = sentData;
        rollbackArgs.withdrawalProof = WithdrawalMerkle.proofForLeaf(withdrawalLeaves, 0);
        rollbackArgs.blockProof = MerkleTree.MerkleProof({nonce: 0, proof: ""});
        _rollbackMessageWithProofNative(l1Bridge, relayer, rollbackArgs);

        assertEq(uint256(l1Bridge.getRollbackMessage(l2FailedMessageHash)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(address(l1Bridge).balance, 0, "L1 bridge should refund locked value");
        assertEq(address(l1Gateway).balance - l1GatewayBalBefore, 1 ether, "L1 gateway should receive refund");

    }

    function test_receiveMessageWithProof_l2ToL1NativeTransfer() public {
        // We focus on the L2 -> L1 proof path:
        // - create an outbound native message on L2 (locks ETH in L2 bridge)
        // - finalize a Rollup batch on L1
        // - execute unlock via `l1Bridge.receiveMessageWithProof(...)`

        // -------- Step 1: Prefund L1 bridge so it can pay out --------
        _selectL1();
        uint256 l1RecipientBalBefore = l1Recipient.balance;
        vm.deal(address(l1Bridge), 1 ether);
        assertEq(address(l1Bridge).balance, 1 ether, "L1 bridge pre-fund missing");

        // -------- Step 2: L2 sends native to L1 --------
        _selectL2();
        vm.deal(l2Recipient, 1 ether);

        // Capture the exact message fields enqueued by l2Bridge.sendMessage.
        vm.recordLogs();
        vm.deal(l2Recipient, 1 ether);
        vm.prank(l2Recipient);
        l2Gateway.sendNativeTokens{value: 1 ether}(l1Recipient);
        assertEq(address(l2Bridge).balance, 1 ether, "L2 bridge should lock value");

        // Decode SentMessage(from, to, value, chainId, blockNumber, nonce, messageHash, data)
        // emitted by the L2 bridge itself.
        bytes memory l2ToL1Message;
        bytes32 l1MessageHash;
        uint256 l1ReceiveNonce;
        uint256 l2ChainIdForProof;
        uint256 l2BlockNumberForProof;

        {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool found;
            uint256 sentValue; // kept only to satisfy abi.decode tuple arity
            for (uint256 i = 0; i < logs.length; i++) {
                Vm.Log memory entry = logs[i];
                if (entry.emitter != address(l2Bridge)) continue;
                if (entry.topics.length != 3) continue;
                if (entry.topics[0] != SENT_MESSAGE_SIG) continue;

                // Decode SentMessage(from, to, value, chainId, blockNumber, nonce, messageHash, data)
                // emitted by the L2 bridge itself.
                (sentValue, l2ChainIdForProof, l2BlockNumberForProof, l1ReceiveNonce, l1MessageHash, l2ToL1Message) = abi.decode(
                    entry.data,
                    (uint256, uint256, uint256, uint256, bytes32, bytes)
                );
                found = true;
                break;
            }
            assertTrue(found, "SentMessage log not found for L2->L1 send");
        }

        // -------- Step 3–4: Finalize + execute unlock via proof path --------
        _finalizeReceiveNativeWithProof(
            l1MessageHash,
            l2ToL1Message,
            l2ChainIdForProof,
            l2BlockNumberForProof,
            l1ReceiveNonce,
            keccak256("l2-native-withdrawal-block"),
            "native-proof-blob",
            relayer
        );

        assertEq(uint256(l1Bridge.getReceivedMessage(l1MessageHash)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(l1Recipient.balance - l1RecipientBalBefore, 1 ether, "L1 recipient didn't get ETH");
        assertEq(address(l1Bridge).balance, 0, "L1 bridge should have forwarded all value");
    }

    /// @dev Accept one L2 block header on L1 rollup, submit one blob, preconfirm, and finalize (used by native flow tests).
    /// @param withdrawalLeaves Message hashes included in this L2 block's withdrawal tree (L2→L1 `SentMessage` and
    ///        L1→L2 timeout `RollbackMessage` hashes, ordered for the test).
    function _finalizeL1SingleBlockBatch(
        bytes32[] memory withdrawalLeaves,
        bytes32 l2BlockHash,
        string memory blobLabel
    ) internal returns (uint256 batchIndex, L2BlockHeader memory header) {
        _selectL1();
        bytes32 withdrawalRoot = WithdrawalMerkle.withdrawalRoot(withdrawalLeaves);
        batchIndex = l1Rollup.nextBatchIndex();
        header = L2BlockHeader({
            previousBlockHash: GENESIS_HASH,
            blockHash: l2BlockHash,
            withdrawalRoot: withdrawalRoot,
            depositRoot: ZERO_BYTES_HASH,
            depositCount: 0
        });
        L2BlockHeader[] memory headers = new L2BlockHeader[](1);
        headers[0] = header;
        vm.prank(relayer);
        l1Rollup.acceptNextBatch(headers, 1);
        bytes32[] memory blobHashes = new bytes32[](1);
        blobHashes[0] = keccak256(abi.encode(blobLabel, batchIndex));
        vm.blobhashes(blobHashes);
        vm.prank(relayer);
        l1Rollup.submitBlobs(batchIndex, 1);
        vm.prank(relayer);
        l1Rollup.preconfirmBatch(address(l1NitroVerifier), batchIndex, DUMMY_SIGNATURE);
        vm.roll(block.number + FINALIZATION_DELAY + 2);
        l1Rollup.finalizeBatches(batchIndex);
        assertTrue(l1Rollup.isBatchFinalized(batchIndex));
    }

    struct ReceiveMessageWithProofArgs {
        uint256 batchIndex;
        L2BlockHeader header;
        address l2Gateway;
        address payable l1Gateway;
        uint256 value;
        uint256 l2ChainId;
        uint256 l2BlockNumber;
        uint256 l1ReceiveNonce;
        bytes message;
        MerkleTree.MerkleProof withdrawalProof;
        MerkleTree.MerkleProof blockProof;
    }

    function _receiveMessageWithProofNative(L1FluentBridge l1Bridge_, address relayer_, ReceiveMessageWithProofArgs memory args) internal {
        vm.prank(relayer_);
        l1Bridge_.receiveMessageWithProof(
            args.batchIndex,
            args.header,
            args.l2Gateway,
            args.l1Gateway,
            args.value,
            args.l2ChainId,
            args.l2BlockNumber,
            args.l1ReceiveNonce,
            args.message,
            args.withdrawalProof,
            args.blockProof
        );
    }

    struct RollbackMessageWithProofArgs {
        uint256 batchIndex;
        L2BlockHeader header;
        address from;
        address payable to;
        uint256 value;
        uint256 l2ChainId;
        uint256 blockNumber;
        uint256 messageNonce;
        bytes message;
        MerkleTree.MerkleProof withdrawalProof;
        MerkleTree.MerkleProof blockProof;
    }

    function _rollbackMessageWithProofNative(L1FluentBridge l1Bridge_, address relayer_, RollbackMessageWithProofArgs memory args) internal {
        vm.prank(relayer_);
        l1Bridge_.rollbackMessageWithProof(
            args.batchIndex,
            args.header,
            args.from,
            args.to,
            args.value,
            args.l2ChainId,
            args.blockNumber,
            args.messageNonce,
            args.message,
            args.withdrawalProof,
            args.blockProof
        );
    }
}
