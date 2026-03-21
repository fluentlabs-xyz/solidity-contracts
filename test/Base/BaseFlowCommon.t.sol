// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {FluentBridgeStorageLayout} from "../../contracts/bridge/FluentBridgeStorageLayout.sol";
import {L1BlockOracle} from "../../contracts/oracle/L1BlockOracle.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {InitConfiguration, L2BlockHeader} from "../../contracts/interfaces/IRollupTypes.sol";
import {MockNitroVerifier} from "../Rollup/mocks/MockNitroVerifier.sol";
import {MockSp1Verifier} from "../Rollup/mocks/MockSp1Verifier.sol";

abstract contract BaseFlowCommon is Test {
    uint256 internal constant RECEIVE_DEADLINE = 100;
    bytes32 internal constant ZERO_BYTES_HASH = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    bytes32 internal constant GENESIS_HASH = keccak256("genesis");
    bytes32 internal constant PROGRAM_VKEY = keccak256("vkey");
    bytes internal constant DUMMY_SIGNATURE =
        abi.encodePacked(keccak256("r"), keccak256("s"), uint8(27));
    uint256 internal constant FINALIZATION_DELAY = 1;
    bytes32 internal constant SENT_MESSAGE_SIG = keccak256("SentMessage(address,address,uint256,uint256,uint256,uint256,bytes32,bytes)");

    uint256 internal l1ForkId;
    uint256 internal l2ForkId;
    uint256 internal l1ChainId;
    uint256 internal l2ChainId;

    address internal admin;
    address internal relayer;
    address internal l1Sender;
    address internal l2Recipient;
    address internal l1Recipient;

    L1FluentBridge internal l1Bridge;
    L2FluentBridge internal l2Bridge;
    Rollup internal l1Rollup;
    MockNitroVerifier internal l1NitroVerifier;
    L1BlockOracle internal l2BlockOracle;

    function setUp() public virtual {
        admin = address(this);
        relayer = makeAddr("relayer");
        l1Sender = makeAddr("l1Sender");
        l2Recipient = makeAddr("l2Recipient");
        l1Recipient = makeAddr("l1Recipient");

        string memory l1RpcUrlOrAlias = vm.envOr("L1_RPC_URL", string("http://127.0.0.1:9545"));
        string memory l2RpcUrlOrAlias = vm.envOr("L2_RPC_URL", string("http://127.0.0.1:9546"));
        l1ForkId = vm.createFork(l1RpcUrlOrAlias);
        l2ForkId = vm.createFork(l2RpcUrlOrAlias);

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

    function _deployOnL1() internal virtual {
        _selectL1();

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
            bridge: address(0xB1),
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

        FluentBridgeStorageLayout.InitConfiguration memory params = FluentBridgeStorageLayout.InitConfiguration({
            adminRole: admin,
            pauserRole: admin,
            relayerRole: relayer,
            otherBridge: address(0xB1)
        });

        L1FluentBridge bridgeImpl = new L1FluentBridge();
        ERC1967Proxy bridgeProxy = new ERC1967Proxy(
            address(bridgeImpl),
            abi.encodeCall(L1FluentBridge.initialize, (abi.encode(params), address(l1Rollup)))
        );
        l1Bridge = L1FluentBridge(payable(address(bridgeProxy)));

        _deployGatewayOnL1();
    }

    function _deployOnL2() internal virtual {
        _selectL2();
        l2BlockOracle = new L1BlockOracle(address(this));

        FluentBridgeStorageLayout.InitConfiguration memory params = FluentBridgeStorageLayout.InitConfiguration({
            adminRole: admin,
            pauserRole: admin,
            relayerRole: relayer,
            otherBridge: address(0xB2)
        });

        L2FluentBridge bridgeImpl = new L2FluentBridge();
        ERC1967Proxy bridgeProxy = new ERC1967Proxy(
            address(bridgeImpl),
            abi.encodeCall(L2FluentBridge.initialize, (abi.encode(params), RECEIVE_DEADLINE, address(l2BlockOracle)))
        );
        l2Bridge = L2FluentBridge(payable(address(bridgeProxy)));

        _deployGatewayOnL2();
    }

    function _linkCrossChain() internal virtual {
        _selectL1();
        l1Bridge.setOtherBridge(address(l2Bridge));
        _selectL2();
        l2Bridge.setOtherBridge(address(l1Bridge));
        _linkGateways();
    }

    function _deployGatewayOnL1() internal virtual;
    function _deployGatewayOnL2() internal virtual;
    function _linkGateways() internal virtual;

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

    function _decodeBridgeSentMessage(Vm.Log[] memory logs, address bridgeAddress)
        internal
        pure
        returns (address from, address to, uint256 value, uint256 chainId, uint256 blockNumber, uint256 nonce, bytes32 messageHash, bytes memory data)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != bridgeAddress || entry.topics.length != 3 || entry.topics[0] != SENT_MESSAGE_SIG) continue;
            from = address(uint160(uint256(entry.topics[1])));
            to = address(uint160(uint256(entry.topics[2])));
            (value, chainId, blockNumber, nonce, messageHash, data) =
                abi.decode(entry.data, (uint256, uint256, uint256, uint256, bytes32, bytes));
            return (from, to, value, chainId, blockNumber, nonce, messageHash, data);
        }
        revert("SentMessage log not found");
    }

    function _finalizeSingleBlockBatch(bytes32 withdrawalRoot) internal returns (uint256 batchIndex, L2BlockHeader memory header) {
        _selectL1();
        batchIndex = l1Rollup.nextBatchIndex();
        header = L2BlockHeader({
            previousBlockHash: GENESIS_HASH,
            blockHash: keccak256(abi.encodePacked("base-flow", withdrawalRoot)),
            withdrawalRoot: withdrawalRoot,
            depositRoot: ZERO_BYTES_HASH,
            depositCount: 0
        });
        L2BlockHeader[] memory headers = new L2BlockHeader[](1);
        headers[0] = header;
        vm.prank(relayer);
        l1Rollup.acceptNextBatch(headers, 1);
        bytes32[] memory blobHashes = new bytes32[](1);
        blobHashes[0] = keccak256(abi.encode("base-flow-blob", batchIndex));
        vm.blobhashes(blobHashes);
        vm.prank(relayer);
        l1Rollup.submitBlobs(batchIndex, 1);
        vm.prank(relayer);
        l1Rollup.preconfirmBatch(address(l1NitroVerifier), batchIndex, DUMMY_SIGNATURE);
        vm.roll(block.number + FINALIZATION_DELAY + 2);
        l1Rollup.finalizeBatches(batchIndex);
        require(l1Rollup.isBatchFinalized(batchIndex), "batch not finalized");
    }
}
