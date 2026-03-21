// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {FluentBridgeStorageLayout} from "../../contracts/bridge/FluentBridgeStorageLayout.sol";

import {L1BlockOracle} from "../../contracts/oracle/L1BlockOracle.sol";
import {NativeGateway} from "../../contracts/gateways/NativeGateway.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";

import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {console2} from "forge-std/console2.sol";
import {InitConfiguration, L2BlockHeader} from "../../contracts/interfaces/IRollupTypes.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";

import {MockNitroVerifier} from "../Rollup/mocks/MockNitroVerifier.sol";
import {MockSp1Verifier} from "../Rollup/mocks/MockSp1Verifier.sol";

contract BaseFlowTest is Test {
    uint256 internal constant RECEIVE_DEADLINE = 100;
    bytes32 internal constant ZERO_BYTES_HASH = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    bytes32 internal constant GENESIS_HASH = keccak256("genesis");
    bytes32 internal constant PROGRAM_VKEY = keccak256("vkey");
    bytes internal constant DUMMY_SIGNATURE =
        abi.encodePacked(keccak256("r"), keccak256("s"), uint8(27));
    uint256 internal constant FINALIZATION_DELAY = 1;
    bytes32 internal constant SENT_MESSAGE_SIG = keccak256("SentMessage(address,address,uint256,uint256,uint256,uint256,bytes32,bytes)");

    function _batchStatusName(uint8 status) internal pure returns (string memory) {
        if (status == 0) return "None";
        if (status == 1) return "HeadersSubmitted";
        if (status == 2) return "Accepted";
        if (status == 3) return "Preconfirmed";
        if (status == 4) return "Challenged";
        if (status == 5) return "Finalized";
        return "Unknown";
    }

    function _logBatchStatus(string memory label, uint256 batchIndex) internal {
        _selectL1();
        uint8 status = uint8(l1Rollup.getBatch(batchIndex).status);
        console2.logString(label);
        console2.log("batchIndex", batchIndex);
        console2.log("batchStatus(uint8)", status);
        console2.logString(_batchStatusName(status));
        console2.log("================================================");
    }

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

    function setUp() public {
        admin = address(this);
        relayer = makeAddr("relayer");
        l1Sender = makeAddr("l1Sender");
        l2Recipient = makeAddr("l2Recipient");
        l1Recipient = makeAddr("l1Recipient");

        // Two separate Anvil nodes are used to simulate L1/L2.
        // Run `scripts/dev/start-anvils.sh` beforehand (defaults: 9545/9546).
        string memory l1RpcUrl = vm.envOr("L1_RPC_URL", string("http://127.0.0.1:9545"));
        string memory l2RpcUrl = vm.envOr("L2_RPC_URL", string("http://127.0.0.1:9546"));
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

        InitConfiguration memory cfg = InitConfiguration({
            admin: admin,
            emergency: admin,
            sequencer: relayer,
            challenger: address(0),
            prover: address(0),
            preconfirmationRole: relayer,
            sp1Verifier: address(sp1),
            nitroVerifier: address(l1NitroVerifier),
            bridge: address(0xB1), // not used because we set depositRoot == ZERO_BYTES_HASH in the test
            programVKey: PROGRAM_VKEY,
            genesisHash: GENESIS_HASH,
            challengeDepositAmount: 1 ether,
            challengeWindow: 0,
            finalizationDelay: FINALIZATION_DELAY,
            acceptDepositDeadline: 1000,
            incentiveFee: 0,
            submitBlobsWindow: 0,
            preconfirmWindow: 1
        });

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
            abi.encodeCall(L2FluentBridge.initialize, (abi.encode(params), RECEIVE_DEADLINE, address(l2BlockOracle)))
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

    function _logL1State(string memory label) internal {
        _selectL1();
        console2.logString(label);
        console2.log("l1Sender", l1Sender);
        console2.log("l1Recipient", l1Recipient);
        console2.log("l1Sender bal", l1Sender.balance);
        console2.log("l1Recipient bal", l1Recipient.balance);
        console2.log("l1Bridge bal", address(l1Bridge).balance);
        console2.log("l1Bridge nonce(out)", l1Bridge.getNonce());
        console2.log("l1Bridge receivedNonce(in)", l1Bridge.getReceivedNonce());
        console2.log("================================================");
    }

    function _logL2State(string memory label) internal {
        _selectL2();
        console2.logString(label);
        console2.log("l2Recipient", l2Recipient);
        console2.log("l2Recipient bal", l2Recipient.balance);
        console2.log("l2Bridge bal", address(l2Bridge).balance);
        console2.log("l2Bridge nonce(out)", l2Bridge.getNonce());
        console2.log("l2Bridge receivedNonce(in)", l2Bridge.getReceivedNonce());
        console2.log("================================================");
    }

    function test_eth_roundtrip_l1_to_l2_and_back_trusted_relayer() public {
        // ============ Step 1: L1 sender sends native to L2 recipient ============
        _logL1State("step1/before");
        _selectL1();
        vm.deal(l1Sender, 1 ether);

        uint256 l1BlockNumber = block.number < 1 ? 1 : block.number;
        uint256 l1OutboundNonce = l1Bridge.getNonce();

        bytes memory l1ToL2Message = abi.encodeCall(NativeGateway.receiveNativeTokens, (l1Sender, l2Recipient, 1 ether));

        vm.prank(l1Sender);
        l1Gateway.sendNativeTokens{value: 1 ether}(l2Recipient, 1 ether);

        assertEq(address(l1Bridge).balance, 1 ether, "L1 bridge should lock funds");
        assertEq(address(l2Bridge).balance, 0, "L2 bridge should start empty");
        _logL1State("step1/after sendNativeTokens");

        // ============ Step 2: Relayer executes on L2 ============
        _logL2State("step2/before receiveMessage");
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
        _logL2State("step2/after receiveMessage");
        console2.logBytes32(l2MessageHash);

        // ============ Step 3: L2 recipient sends back to L1 recipient ============
        uint256 l2ChainIdForProof;
        uint256 l2BlockNumberForProof;
        uint256 l1ReceiveNonce;
        bytes32 l1MessageHash;
        _logL2State("step3/before return sendNativeTokens");
        uint256 l2OutboundNonce = l2Bridge.getNonce();

        bytes memory l2ToL1Message = abi.encodeCall(NativeGateway.receiveNativeTokens, (l2Recipient, l1Recipient, 1 ether));

        assertEq(l2Bridge.getNonce(), l2OutboundNonce, "sanity");
        vm.recordLogs();
        vm.prank(l2Recipient);
        l2Gateway.sendNativeTokens{value: 1 ether}(l1Recipient, 1 ether);

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

        _logL2State("step3/after return sendNativeTokens");

        // ============ Step 4: Relayer executes return on L1 ============
        _logL1State("step4/before receiveMessage");
        _selectL1();
        uint256 l1PreRecipientBal = l1Recipient.balance;
        assertEq(address(l1Bridge).balance, 1 ether, "L1 bridge should have funds to unlock");

        // l2ChainIdForProof / l2BlockNumberForProof / l1ReceiveNonce / l1MessageHash
        // are extracted from the L2 SentMessage event above.

        // -------- rollup: accept + finalize batch so receiveMessageWithProof passes --------
        uint256 batchIndex;
        L2BlockHeader memory header;
        (batchIndex, header) = _finalizeL1SingleBlockBatch(
            l1MessageHash,
            keccak256("l2-withdrawal-block"),
            "native-flow-blob"
        );

        // -------- execute withdrawal via proof path --------
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
        callArgs.withdrawalProof = MerkleTree.MerkleProof({nonce: 0, proof: ""});
        callArgs.blockProof = MerkleTree.MerkleProof({nonce: 0, proof: ""});
        _receiveMessageWithProofNative(l1Bridge, relayer, callArgs);

        assertEq(uint256(l1Bridge.getReceivedMessage(l1MessageHash)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(l1Recipient.balance - l1PreRecipientBal, 1 ether, "L1 recipient didn't get ETH back");
        assertEq(address(l1Bridge).balance, 0, "L1 bridge should have forwarded all locked value");
        _logL1State("step4/after receiveMessage");
        console2.logBytes32(l1MessageHash);
    }

    function test_rollback_l1_to_l2_deadline_refunds_on_l1() public {
        // ============ Step 1: L1 sender sends native to L2 recipient ============
        _logL1State("rollback/step1/before sendNativeTokens");
        _selectL1();
        vm.deal(l1Sender, 1 ether);

        uint256 l1OutboundNonce = l1Bridge.getNonce();
        bytes memory l1ToL2Message = abi.encodeCall(NativeGateway.receiveNativeTokens, (l1Sender, l2Recipient, 1 ether));

        vm.recordLogs();
        vm.prank(l1Sender);
        l1Gateway.sendNativeTokens{value: 1 ether}(l2Recipient, 1 ether);

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

        _logL1State("rollback/step1/after sendNativeTokens");

        // ============ Step 2: Relayer tries receiveMessage on L2, but deadline expires ============
        _logL2State("rollback/step2/before receiveMessage (expect rollback)");
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
        _logL2State("rollback/step2/after receiveMessage (failed marked)");

        // ============ Step 3: Finalize rollup batch on L1 containing the rollback withdrawalRoot ============
        _logL1State("rollback/step3/before finalize batch");
        _selectL1();

        uint256 batchIndex;
        L2BlockHeader memory header;
        (batchIndex, header) = _finalizeL1SingleBlockBatch(
            l2FailedMessageHash,
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
        rollbackArgs.withdrawalProof = MerkleTree.MerkleProof({nonce: 0, proof: ""});
        rollbackArgs.blockProof = MerkleTree.MerkleProof({nonce: 0, proof: ""});
        _rollbackMessageWithProofNative(l1Bridge, relayer, rollbackArgs);

        assertEq(uint256(l1Bridge.getRollbackMessage(l2FailedMessageHash)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(address(l1Bridge).balance, 0, "L1 bridge should refund locked value");
        assertEq(address(l1Gateway).balance - l1GatewayBalBefore, 1 ether, "L1 gateway should receive refund");

        _logL1State("rollback/step4/after rollbackMessageWithProof");
    }

    function test_receiveMessageWithProof_l2_to_l1_native_happy_path() public {
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
        l2Gateway.sendNativeTokens{value: 1 ether}(l1Recipient, 1 ether);
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

        // -------- Step 3: Create + finalize Rollup batch on L1 --------
        uint256 batchIndex;
        L2BlockHeader memory header;
        (batchIndex, header) = _finalizeL1SingleBlockBatch(
            l1MessageHash,
            keccak256("l2-native-withdrawal-block"),
            "native-proof-blob"
        );

        // -------- Step 4: Execute unlock via proof path --------
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
        callArgs.withdrawalProof = MerkleTree.MerkleProof({nonce: 0, proof: ""});
        callArgs.blockProof = MerkleTree.MerkleProof({nonce: 0, proof: ""});
        _receiveMessageWithProofNative(l1Bridge, relayer, callArgs);

        assertEq(uint256(l1Bridge.getReceivedMessage(l1MessageHash)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(l1Recipient.balance - l1RecipientBalBefore, 1 ether, "L1 recipient didn't get ETH");
        assertEq(address(l1Bridge).balance, 0, "L1 bridge should have forwarded all value");
    }

    /// @dev Accept one L2 block header on L1 rollup, submit one blob, preconfirm, and finalize (used by native flow tests).
    function _finalizeL1SingleBlockBatch(
        bytes32 withdrawalRoot,
        bytes32 l2BlockHash,
        string memory blobLabel
    ) internal returns (uint256 batchIndex, L2BlockHeader memory header) {
        _selectL1();
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
