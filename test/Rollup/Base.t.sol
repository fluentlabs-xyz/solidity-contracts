// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FluentBridge as Bridge} from "../../contracts/FluentBridge.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {VerifierMock} from "../../contracts/mocks/VerifierMock.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {RollupStorageLayout} from "../../contracts/rollup/RollupStorage.sol";
import {SP1Verifier} from "../../contracts/verifier/SP1VerifierGroth16.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function deal(address account, uint256 newBalance) external;
    function expectRevert() external;
    function expectRevert(bytes calldata revertData) external;
    function expectRevert(bytes4 revertData) external;
    function prank(address msgSender) external;
    function startPrank(address msgSender) external;
    function stopPrank() external;
    function roll(uint256 newHeight) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
    function targetContract(address newTargetedContract_) external;
}

abstract contract MinimalTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertTrue(bool condition, string memory message) internal pure {
        require(condition, message);
    }

    function assertEq(uint256 left, uint256 right, string memory message) internal pure {
        require(left == right, message);
    }

    function assertEq(int256 left, int256 right, string memory message) internal pure {
        require(left == right, message);
    }

    function assertEq(address left, address right, string memory message) internal pure {
        require(left == right, message);
    }

    function assertEq(bytes32 left, bytes32 right, string memory message) internal pure {
        require(left == right, message);
    }

    function assertEq(bool left, bool right, string memory message) internal pure {
        require(left == right, message);
    }

    function assertEq(bytes memory left, bytes memory right, string memory message) internal pure {
        require(keccak256(left) == keccak256(right), message);
    }

    function assertLe(uint256 left, uint256 right, string memory message) internal pure {
        require(left <= right, message);
    }

    function assertGt(uint256 left, uint256 right, string memory message) internal pure {
        require(left > right, message);
    }
}

abstract contract RollupBase is MinimalTest {
    bytes32 internal constant ZERO_HASH = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    bytes32 internal constant MOCK_VK_KEY = 0x00612f9d5a388df116872ff70e36bcb86c7e73b1089f32f68fc8e0d0ba7861b7;
    bytes32 internal constant MOCK_GENESIS_HASH = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    bytes32 internal constant SP1_VK_KEY = 0x00440704be87894021b2b5673900bf717ec670dcfde36f7bf371f9ae1a02f46e;
    bytes32 internal constant SP1_GENESIS_HASH = 0x9d06b07ccbd86a2fc8ab4145d909873c09d92bbce87f98f33699ff3733e91a2c;

    address internal constant SEQUENCER = address(0xA11CE);
    address internal constant CHALLENGER = address(0xB0B);
    address internal constant PROOF_PROVIDER = address(0xCAFE);
    address internal constant ATTACKER = address(0xBAD);

    Rollup internal rollup;
    Bridge internal bridge;
    VerifierMock internal verifierMock;
    SP1Verifier internal verifierSp1;

    function _deployRollupProxy(RollupStorageLayout.InitConfiguration memory params) internal returns (Rollup) {
        Rollup rollupImpl = new Rollup();
        if (params.pauser == address(0)) params.pauser = params.admin;
        bytes memory initData = abi.encodeCall(Rollup.initialize, (abi.encode(params)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(rollupImpl), initData);
        return Rollup(payable(address(proxy)));
    }

    function _deployBridge(
        address initialOwner,
        address bridgeAuthority,
        address rollupAddress,
        uint256 receiveMessageDeadline,
        address otherBridge,
        address l1BlockOracle
    ) internal returns (Bridge) {
        Bridge bridgeImpl = new Bridge();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(bridgeImpl),
            abi.encodeCall(Bridge.initialize, (initialOwner, bridgeAuthority, rollupAddress, receiveMessageDeadline, otherBridge, l1BlockOracle))
        );
        return Bridge(payable(address(proxy)));
    }

    function _deployMockRollup(
        uint256 batchSize_,
        uint256 challengeDepositAmount_,
        uint256 challengeBlockCount_,
        uint256 approveBlockCount_,
        uint256 acceptDepositDeadline_,
        uint256 incentiveFee_
    ) internal {
        verifierMock = new VerifierMock();
        bridge = _deployBridge(
            address(this),
            address(this), // bridgeAuthority unused in these unit tests
            address(0),
            0,
            address(0x1111),
            address(0x2222)
        );
        rollup = _deployRollupProxy(
            RollupStorageLayout.InitConfiguration({
                admin: address(this),
                pauser: address(0),
                sequencer: SEQUENCER,
                challengeDepositAmount: challengeDepositAmount_,
                challengeBlockCount: challengeBlockCount_,
                approveBlockCount: approveBlockCount_,
                verifier: address(verifierMock),
                programVKey: MOCK_VK_KEY,
                genesisHash: MOCK_GENESIS_HASH,
                bridge: address(bridge),
                batchSize: batchSize_,
                acceptDepositDeadline: acceptDepositDeadline_,
                incentiveFee: incentiveFee_,
                challenger: CHALLENGER,
                prover: PROOF_PROVIDER
            })
        );
        rollup.setDaCheck(false);
    }

    function _deployMockRollupWithLinkedBridgeQueue(
        uint256 batchSize_,
        uint256 challengeDepositAmount_,
        uint256 challengeBlockCount_,
        uint256 approveBlockCount_,
        uint256 acceptDepositDeadline_,
        uint256 incentiveFee_
    ) internal {
        verifierMock = new VerifierMock();
        rollup = _deployRollupProxy(
            RollupStorageLayout.InitConfiguration({
                admin: address(this),
                pauser: address(0),
                sequencer: SEQUENCER,
                challengeDepositAmount: challengeDepositAmount_,
                challengeBlockCount: challengeBlockCount_,
                approveBlockCount: approveBlockCount_,
                verifier: address(verifierMock),
                programVKey: MOCK_VK_KEY,
                genesisHash: MOCK_GENESIS_HASH,
                bridge: address(0x1),
                batchSize: batchSize_,
                acceptDepositDeadline: acceptDepositDeadline_,
                incentiveFee: incentiveFee_,
                challenger: CHALLENGER,
                prover: PROOF_PROVIDER
            })
        );
        bridge = _deployBridge(address(this), address(this), address(rollup), 0, address(0x1111), address(0x2222));
        rollup.setBridge(address(bridge));
        rollup.setDaCheck(false);
    }

    function _deploySp1RollupForVerifierPath() internal {
        verifierSp1 = new SP1Verifier();
        bridge = _deployBridge(address(this), address(this), address(0), 0, address(0x1111), address(0x2222));
        rollup = _deployRollupProxy(
            RollupStorageLayout.InitConfiguration({
                admin: address(this),
                pauser: address(0),
                sequencer: SEQUENCER,
                challengeDepositAmount: 10000,
                challengeBlockCount: 0,
                approveBlockCount: 1,
                verifier: address(verifierSp1),
                programVKey: SP1_VK_KEY,
                genesisHash: SP1_GENESIS_HASH,
                bridge: address(bridge),
                batchSize: 1,
                acceptDepositDeadline: 10,
                incentiveFee: 1000,
                challenger: CHALLENGER,
                prover: PROOF_PROVIDER
            })
        );
        rollup.setDaCheck(false);
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

    function _commitmentHash(RollupStorageLayout.BlockCommitment memory commitment) internal pure returns (bytes32) {
        return
            keccak256(abi.encodePacked(commitment.previousBlockHash, commitment.blockHash, commitment.withdrawalHash, commitment.depositHash));
    }

    function _proofForSingleLeaf() internal pure returns (MerkleTree.MerkleProof memory) {
        return MerkleTree.MerkleProof({nonce: 0, proof: ""});
    }

    function _proofForTwoLeaves(uint256 indexInBatch, bytes32 sibling) internal pure returns (MerkleTree.MerkleProof memory) {
        return MerkleTree.MerkleProof({nonce: indexInBatch, proof: abi.encodePacked(sibling)});
    }

    function _hashPair(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(left, right));
    }

    function _bridgeMessageHash(
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber_,
        uint256 nonce_,
        bytes memory message
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(from, to, value, chainId, blockNumber_, nonce_, message));
    }
}
