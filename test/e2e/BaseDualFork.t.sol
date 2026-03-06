// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Vm.sol";

import {FluentBridge as Bridge} from "../../contracts/FluentBridge.sol";
import {PaymentsGateway} from "../../contracts/gateways/PaymentsGateway.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {MockERC20Token} from "../../contracts/mocks/MockERC20.sol";
import {VerifierMock} from "../../contracts/mocks/VerifierMock.sol";
import {L1BlockOracle} from "../../contracts/oracle/L1BlockOracle.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {RollupStorageLayout} from "../../contracts/rollup/RollupStorageLayout.sol";
import {MockBlobHashGetter} from "./mocks/MockBlobHashGetter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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
    Vm internal constant vmStd = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

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
        Rollup rollupImpl = new Rollup();
        RollupStorageLayout.InitConfiguration memory initParams = RollupStorageLayout.InitConfiguration({
            admin: address(this),
            pauser: address(0),
            sequencer: SEQUENCER,
            challengeDepositAmount: 10000,
            challengeBlockCount: 20,
            approveBlockCount: 0,
            verifier: address(l1.verifier),
            programVKey: MOCK_VK_KEY,
            genesisHash: MOCK_GENESIS_HASH,
            bridge: address(0),
            batchSize: batchSize,
            acceptDepositDeadline: 100,
            incentiveFee: 0,
            challenger: address(0),
            prover: address(0)
        });
        ERC1967Proxy rollupProxy = new ERC1967Proxy(address(rollupImpl), abi.encodeCall(Rollup.initialize, (abi.encode(initParams))));
        l1.rollup = Rollup(payable(address(rollupProxy)));

        // Deploy FluentBridge behind an ERC1967 proxy and initialize it.
        Bridge bridgeImplL1 = new Bridge();
        ERC1967Proxy bridgeProxyL1 = new ERC1967Proxy(
            address(bridgeImplL1),
            abi.encodeCall(
                Bridge.initialize,
                (
                    address(this),
                    BRIDGE_AUTHORITY,
                    address(l1.rollup),
                    0, // receiveMessageDeadline = 0 on L1
                    address(0),
                    address(l1.oracle)
                )
            )
        );
        l1.bridge = Bridge(payable(address(bridgeProxyL1)));
        l1.rollup.setBridge(address(l1.bridge));
        l1.rollup.setDaCheck(false);

        l1BlobHashGetter = new MockBlobHashGetter();

        l1.peggedImpl = new ERC20PeggedToken();

        // Deploy ERC20TokenFactory behind an ERC1967 proxy and initialize it.
        ERC20TokenFactory factoryImplL1 = new ERC20TokenFactory();
        ERC1967Proxy factoryProxyL1 = new ERC1967Proxy(
            address(factoryImplL1),
            abi.encodeCall(ERC20TokenFactory.initialize, (address(this), address(l1.peggedImpl)))
        );
        l1.factory = ERC20TokenFactory(payable(address(factoryProxyL1)));

        // Deploy PaymentsGateway behind an ERC1967 proxy and initialize it.
        PaymentsGateway gatewayImplL1 = new PaymentsGateway();
        ERC1967Proxy gatewayProxyL1 = new ERC1967Proxy(
            address(gatewayImplL1),
            abi.encodeCall(PaymentsGateway.initialize, (address(this), address(l1.bridge), address(l1.factory)))
        );
        l1.gateway = PaymentsGateway(payable(address(gatewayProxyL1)));
        l1.factory.transferOwnership(address(l1.gateway));
        l1.gateway.acceptTokenFactory();

        // Make core L1 contracts persistent across forks so they can be referenced safely from L2.
        address[] memory l1Contracts = new address[](7);
        l1Contracts[0] = address(l1.rollup);
        l1Contracts[1] = address(l1.bridge);
        l1Contracts[2] = address(l1.gateway);
        l1Contracts[3] = address(l1.factory);
        l1Contracts[4] = address(l1.peggedImpl);
        l1Contracts[5] = address(l1.verifier);
        l1Contracts[6] = address(l1.oracle);
        vmStd.makePersistent(l1Contracts);
    }

    function _deployL2() internal {
        _switchToL2();
        _assertOnL2();
        l2.chainId = block.chainid;

        l2.oracle = new L1BlockOracle();
        Bridge bridgeImplL2 = new Bridge();
        ERC1967Proxy bridgeProxyL2 = new ERC1967Proxy(
            address(bridgeImplL2),
            abi.encodeCall(
                Bridge.initialize,
                (
                    address(this),
                    BRIDGE_AUTHORITY,
                    address(0), // rollup is not used on L2 in these tests
                    100, // non-zero deadline to allow rollback window
                    address(0),
                    address(l2.oracle)
                )
            )
        );
        l2.bridge = Bridge(payable(address(bridgeProxyL2)));

        l2.peggedImpl = new ERC20PeggedToken();

        // Deploy ERC20TokenFactory behind an ERC1967 proxy and initialize it.
        ERC20TokenFactory factoryImplL2 = new ERC20TokenFactory();
        ERC1967Proxy factoryProxyL2 = new ERC1967Proxy(
            address(factoryImplL2),
            abi.encodeCall(ERC20TokenFactory.initialize, (address(this), address(l2.peggedImpl)))
        );
        l2.factory = ERC20TokenFactory(payable(address(factoryProxyL2)));

        // Deploy PaymentsGateway behind an ERC1967 proxy and initialize it.
        PaymentsGateway gatewayImplL2 = new PaymentsGateway();
        ERC1967Proxy gatewayProxyL2 = new ERC1967Proxy(
            address(gatewayImplL2),
            abi.encodeCall(PaymentsGateway.initialize, (address(this), address(l2.bridge), address(l2.factory)))
        );
        l2.gateway = PaymentsGateway(payable(address(gatewayProxyL2)));
        l2.factory.transferOwnership(address(l2.gateway));
        l2.gateway.acceptTokenFactory();

        l2.originToken = new MockERC20Token("Mock Token", "TKN", INITIAL_SUPPLY, USER_A);

        // Make core L2 contracts persistent across forks so they can be referenced safely from L1.
        address[] memory l2Contracts = new address[](6);
        l2Contracts[0] = address(l2.bridge);
        l2Contracts[1] = address(l2.gateway);
        l2Contracts[2] = address(l2.factory);
        l2Contracts[3] = address(l2.peggedImpl);
        l2Contracts[4] = address(l2.originToken);
        l2Contracts[5] = address(l2.oracle);
        vmStd.makePersistent(l2Contracts);
    }

    function _linkCrossChain() internal {
        _switchToL2();
        _assertOnL2();
        address l2Beacon = l2.factory.beacon();

        _switchToL1();
        _assertOnL1();
        address l1Beacon = l1.factory.beacon();
        l1.bridge.setOtherBridge(address(l2.bridge));
        l1.gateway.setOtherSide(address(l2.gateway), address(l2.peggedImpl), address(l2.factory), l2Beacon);

        _switchToL2();
        _assertOnL2();
        l2.bridge.setOtherBridge(address(l1.bridge));
        l2.gateway.setOtherSide(address(l1.gateway), address(l1.peggedImpl), address(l1.factory), l1Beacon);
    }

    function _buildCommitment(
        bytes32 previousBlockHash,
        bytes32 blockHash,
        bytes32 withdrawalHash,
        bytes32 depositHash
    ) internal pure returns (RollupStorageLayout.BlockCommitment memory commitment) {
        commitment = RollupStorageLayout.BlockCommitment({
            previousBlockHash: previousBlockHash,
            blockHash: blockHash,
            withdrawalHash: withdrawalHash,
            depositHash: depositHash
        });
    }

    function _singleLeafProof() internal pure returns (MerkleTree.MerkleProof memory) {
        return MerkleTree.MerkleProof({nonce: 0, proof: ""});
    }

    function _syncDaBlobHashForBatch(RollupStorageLayout.BlockCommitment[] memory batch) internal {
        // Keep DA check fail-closed by setting expected blob hash before acceptance.
        _assertOnL1();
        bytes32 batchRoot = l1.rollup.calculateBatchRoot(batch);
        bytes32 expectedBlobHash = l1.rollup.calculateBlobHash(abi.encodePacked(batchRoot));
        l1BlobHashGetter.setBlobHash(expectedBlobHash);
    }

    function _acceptBatchL1(RollupStorageLayout.BlockCommitment[] memory batch, RollupStorageLayout.DepositsInBlock[] memory deposits) internal {
        // Accepting a batch mutates rollup state and may consume bridge queue deposits.
        _switchToL1();
        _assertOnL1();
        _syncDaBlobHashForBatch(batch);

        vm.prank(SEQUENCER);
        l1.rollup.acceptNextBatch(batch, deposits, 0);
    }

    function _acceptSingleCommitmentBatchL1(
        RollupStorageLayout.BlockCommitment memory commitment,
        RollupStorageLayout.DepositsInBlock[] memory deposits
    ) internal {
        RollupStorageLayout.BlockCommitment[] memory batch = new RollupStorageLayout.BlockCommitment[](1);
        batch[0] = commitment;
        _acceptBatchL1(batch, deposits);
    }

    function _commitmentHash(RollupStorageLayout.BlockCommitment memory commitment) internal pure returns (bytes32) {
        return
            keccak256(abi.encodePacked(commitment.previousBlockHash, commitment.blockHash, commitment.withdrawalHash, commitment.depositHash));
    }

    function _buildBlockProof(
        RollupStorageLayout.BlockCommitment[] memory batch,
        uint256 index
    ) internal pure returns (MerkleTree.MerkleProof memory) {
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
