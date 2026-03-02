// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FluentBridge as Bridge} from "../../contracts/FluentBridge.sol";
import {PaymentsGateway} from "../../contracts/gateways/PaymentsGateway.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {MockERC20Token} from "../../contracts/mocks/MockERC20.sol";
import {VerifierMock} from "../../contracts/mocks/VerifierMock.sol";
import {L1BlockOracle} from "../../contracts/oracle/L1BlockOracle.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {MockBlobHashGetter} from "./mocks/MockBlobHashGetter.sol";

interface VmFork {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function createFork(string calldata urlOrAlias) external returns (uint256);
    function selectFork(uint256 forkId) external;
    function activeFork() external returns (uint256);
    function prank(address msgSender) external;
    function startPrank(address msgSender) external;
    function stopPrank() external;
    function expectRevert(bytes calldata revertData) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
    function roll(uint256 newHeight) external;
    function deal(address who, uint256 newBalance) external;
}

abstract contract BaseDualFork {
    VmFork internal constant vm = VmFork(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 internal constant ZERO_HASH = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    bytes32 internal constant MOCK_VK_KEY = 0x00612f9d5a388df116872ff70e36bcb86c7e73b1089f32f68fc8e0d0ba7861b7;
    bytes32 internal constant MOCK_GENESIS_HASH = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    uint256 internal constant INITIAL_SUPPLY = 1_000_000 ether;

    address internal constant SEQUENCER = address(0xA11CE);
    address internal constant BRIDGE_AUTHORITY = address(0xB0A7);
    address internal constant USER_A = address(0xAA01);
    address internal constant USER_B = address(0xBB02);

    bytes32 internal constant SENT_MESSAGE_SIG = keccak256("SentMessage(address,address,uint256,uint256,uint256,uint256,bytes32,bytes)");

    struct SentMessageData {
        address sender;
        address to;
        uint256 value;
        uint256 chainId;
        uint256 blockNumber;
        uint256 nonce;
        bytes32 messageHash;
        bytes data;
    }

    struct ChainCtx {
        uint256 forkId;
        uint256 chainId;
        Bridge bridge;
        PaymentsGateway gateway;
        ERC20TokenFactory factory;
        ERC20PeggedToken peggedImpl;
        MockERC20Token originToken;
        Rollup rollup;
        VerifierMock verifier;
        L1BlockOracle oracle;
    }

    ChainCtx internal l1;
    ChainCtx internal l2;
    MockBlobHashGetter internal l1BlobHashGetter;

    function _setUpDualFork() internal {
        _setUpDualForkWithL1BatchSize(1);
    }

    function _setUpDualForkWithL1BatchSize(uint256 l1BatchSize) internal {
        l1.forkId = vm.createFork("l1");
        l2.forkId = vm.createFork("l2");

        _deployL1(l1BatchSize);
        _deployL2();
        _linkCrossChain();

        require(l1.chainId != l2.chainId, "L1 and L2 chain IDs must differ");
    }

    // Switches execution context to L1 fork.
    // Every call after this runs on L1 until next explicit switch.
    function _switchToL1() internal {
        vm.selectFork(l1.forkId);
    }

    // Switches execution context to L2 fork.
    // Every call after this runs on L2 until next explicit switch.
    function _switchToL2() internal {
        vm.selectFork(l2.forkId);
    }

    function _assertOnL1() internal {
        require(vm.activeFork() == l1.forkId, "active fork is not L1");
    }

    function _assertOnL2() internal {
        require(vm.activeFork() == l2.forkId, "active fork is not L2");
    }

    function _deployL1(uint256 batchSize) internal {
        _switchToL1();
        _assertOnL1();
        l1.chainId = block.chainid;

        l1.verifier = new VerifierMock();
        l1.oracle = new L1BlockOracle();
        l1.rollup = new Rollup(SEQUENCER, 10000, 20, 0, address(l1.verifier), MOCK_VK_KEY, MOCK_GENESIS_HASH, address(0), batchSize, 100, 0);

        // Deploy FluentBridge implementation (no proxy) and initialize it.
        l1.bridge = new Bridge();
        l1.bridge.initialize(
            address(this),
            BRIDGE_AUTHORITY,
            address(l1.rollup),
            0, // receiveMessageDeadline = 0 on L1
            address(0),
            address(l1.oracle)
        );
        l1.rollup.setBridge(address(l1.bridge));
        l1.rollup.setDaCheck(true);

        l1BlobHashGetter = new MockBlobHashGetter();
        l1.rollup.setBlobHashGetter(address(l1BlobHashGetter));

        l1.peggedImpl = new ERC20PeggedToken();

        l1.factory = new ERC20TokenFactory();
        l1.factory.initialize(address(this), address(l1.peggedImpl));

        // Deploy PaymentsGateway implementation and initialize it (tests don't use proxies).
        l1.gateway = new PaymentsGateway();
        l1.gateway.initialize(address(this), address(l1.bridge), address(l1.factory));
        l1.factory.transferOwnership(address(l1.gateway));
        l1.gateway.acceptTokenFactory();
    }

    function _deployL2() internal {
        _switchToL2();
        _assertOnL2();
        l2.chainId = block.chainid;

        l2.bridge = new Bridge();
        l2.bridge.initialize(
            address(this),
            BRIDGE_AUTHORITY,
            address(0), // rollup is not used on L2 in these tests
            100, // non-zero deadline to allow rollback window
            address(0),
            address(0)
        );

        l2.peggedImpl = new ERC20PeggedToken();
        l2.factory = new ERC20TokenFactory();
        l2.factory.initialize(address(this), address(l2.peggedImpl));

        l2.gateway = new PaymentsGateway();
        l2.gateway.initialize(address(this), address(l2.bridge), address(l2.factory));
        l2.factory.transferOwnership(address(l2.gateway));
        l2.gateway.acceptTokenFactory();

        l2.originToken = new MockERC20Token("Mock Token", "TKN", INITIAL_SUPPLY, USER_A);
    }

    function _linkCrossChain() internal {
        _switchToL1();
        _assertOnL1();
        l1.bridge.setOtherBridge(address(l2.bridge));
        l1.gateway.setOtherSide(address(l2.gateway), address(l2.peggedImpl), address(l2.factory));

        _switchToL2();
        _assertOnL2();
        l2.bridge.setOtherBridge(address(l1.bridge));
        l2.gateway.setOtherSide(address(l1.gateway), address(l1.peggedImpl), address(l1.factory));
    }

    function _buildCommitment(
        bytes32 previousBlockHash,
        bytes32 blockHash,
        bytes32 withdrawalHash,
        bytes32 depositHash
    ) internal pure returns (Rollup.BlockCommitment memory commitment) {
        commitment = Rollup.BlockCommitment({
            previousBlockHash: previousBlockHash,
            blockHash: blockHash,
            withdrawalHash: withdrawalHash,
            depositHash: depositHash
        });
    }

    function _singleLeafProof() internal pure returns (MerkleTree.MerkleProof memory) {
        return MerkleTree.MerkleProof({nonce: 0, proof: ""});
    }

    function _syncDaBlobHashForBatch(Rollup.BlockCommitment[] memory batch) internal {
        // Keep DA check fail-closed by setting expected blob hash before acceptance.
        _assertOnL1();
        bytes32 batchRoot = l1.rollup.calculateBatchRoot(batch);
        bytes32 expectedBlobHash = l1.rollup.calculateBlobHash(abi.encodePacked(batchRoot));
        l1BlobHashGetter.setBlobHash(expectedBlobHash);
    }

    function _acceptBatchL1(uint256 batchIndex, Rollup.BlockCommitment[] memory batch, Rollup.DepositsInBlock[] memory deposits) internal {
        // Accepting a batch mutates rollup state and may consume bridge queue deposits.
        _switchToL1();
        _assertOnL1();
        _syncDaBlobHashForBatch(batch);

        vm.prank(SEQUENCER);
        l1.rollup.acceptNextBatch(batchIndex, batch, deposits);
    }

    function _acceptSingleCommitmentBatchL1(
        uint256 batchIndex,
        Rollup.BlockCommitment memory commitment,
        Rollup.DepositsInBlock[] memory deposits
    ) internal {
        Rollup.BlockCommitment[] memory batch = new Rollup.BlockCommitment[](1);
        batch[0] = commitment;
        _acceptBatchL1(batchIndex, batch, deposits);
    }

    function _commitmentHash(Rollup.BlockCommitment memory commitment) internal pure returns (bytes32) {
        return
            keccak256(abi.encodePacked(commitment.previousBlockHash, commitment.blockHash, commitment.withdrawalHash, commitment.depositHash));
    }

    function _buildBlockProof(Rollup.BlockCommitment[] memory batch, uint256 index) internal pure returns (MerkleTree.MerkleProof memory) {
        require(index < batch.length, "proof index out of range");

        bytes32[] memory level = new bytes32[](batch.length);
        for (uint256 i = 0; i < batch.length; i++) {
            level[i] = _commitmentHash(batch[i]);
        }

        uint256 idx = index;
        bytes memory siblings;
        while (level.length > 1) {
            uint256 pairIndex = idx ^ 1;
            bytes32 sibling = pairIndex < level.length ? level[pairIndex] : level[idx];
            siblings = abi.encodePacked(siblings, sibling);

            uint256 nextCount = (level.length + 1) / 2;
            bytes32[] memory next = new bytes32[](nextCount);
            for (uint256 i = 0; i < nextCount; i++) {
                uint256 leftIndex = i * 2;
                uint256 rightIndex = leftIndex + 1;
                bytes32 left = level[leftIndex];
                bytes32 right = rightIndex < level.length ? level[rightIndex] : left;
                next[i] = keccak256(abi.encodePacked(left, right));
            }
            idx /= 2;
            level = next;
        }

        return MerkleTree.MerkleProof({nonce: index, proof: siblings});
    }

    function _findSentMessage(VmFork.Log[] memory logs, address bridgeAddress) internal pure returns (SentMessageData memory out) {
        SentMessageData[] memory messages = _collectSentMessages(logs, bridgeAddress);
        require(messages.length != 0, "SentMessage log not found");
        return messages[0];
    }

    function _collectSentMessages(VmFork.Log[] memory logs, address bridgeAddress) internal pure returns (SentMessageData[] memory out) {
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            VmFork.Log memory entry = logs[i];
            if (entry.emitter == bridgeAddress && entry.topics.length == 3 && entry.topics[0] == SENT_MESSAGE_SIG) {
                count++;
            }
        }
        out = new SentMessageData[](count);

        uint256 cursor;
        for (uint256 i = 0; i < logs.length; i++) {
            VmFork.Log memory entry = logs[i];
            if (entry.emitter == bridgeAddress && entry.topics.length == 3 && entry.topics[0] == SENT_MESSAGE_SIG) {
                out[cursor].sender = address(uint160(uint256(entry.topics[1])));
                out[cursor].to = address(uint160(uint256(entry.topics[2])));
                (
                    out[cursor].value,
                    out[cursor].chainId,
                    out[cursor].blockNumber,
                    out[cursor].nonce,
                    out[cursor].messageHash,
                    out[cursor].data
                ) = abi.decode(entry.data, (uint256, uint256, uint256, uint256, bytes32, bytes));
                cursor++;
            }
        }
    }

    function assertEq(uint256 left, uint256 right, string memory message) internal pure {
        require(left == right, message);
    }

    function assertEq(address left, address right, string memory message) internal pure {
        require(left == right, message);
    }

    function assertEq(bytes32 left, bytes32 right, string memory message) internal pure {
        require(left == right, message);
    }

    function assertTrue(bool condition, string memory message) internal pure {
        require(condition, message);
    }

    function assertEq(bool left, bool right, string memory message) internal pure {
        require(left == right, message);
    }
}
