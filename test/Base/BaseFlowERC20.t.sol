// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IGatewayBaseErrors} from "../../contracts/interfaces/gateways/IGatewayBase.sol";

import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {FluentBridgeStorageLayout} from "../../contracts/bridge/FluentBridgeStorageLayout.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";
import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {MockERC20Token} from "../../test/mocks/MockERC20.sol";
import {L1BlockOracle} from "../../contracts/oracles/L1BlockOracle.sol";
import {L1GasOracle} from "../../contracts/oracles/L1GasOracle.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {InitConfiguration, L2BlockHeader} from "../../contracts/interfaces/IRollupTypes.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {WithdrawalMerkle} from "../helpers/WithdrawalMerkle.sol";
import {MockNitroVerifier} from "../mocks/MockNitroVerifier.sol";
import {MockSp1Verifier} from "../mocks/MockSp1Verifier.sol";

contract BaseFlowERC20Test is Test {
    uint256 internal constant RECEIVE_DEADLINE = 100;
    bytes32 internal constant ZERO_BYTES_HASH = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    bytes32 internal constant GENESIS_HASH = keccak256("genesis");
    bytes32 internal constant PROGRAM_VKEY = keccak256("vkey");
    bytes internal constant DUMMY_SIGNATURE = abi.encodePacked(keccak256("r"), keccak256("s"), uint8(27));

    uint256 internal constant FINALIZATION_DELAY = 1;
    uint256 internal constant MAX_FORCE_REVERT_BATCH_SIZE = 10;
    bytes32 internal constant SENT_MESSAGE_SIG = keccak256("SentMessage(address,address,uint256,uint256,uint256,uint256,bytes32,bytes)");
    uint256 internal constant AMOUNT = 100 ether;

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
    L1GasOracle internal l2GasOracle;

    ERC20Gateway internal l1Gateway;
    ERC20Gateway internal l2Gateway;
    ERC20TokenFactory internal l1Factory;
    ERC20TokenFactory internal l2Factory;
    address internal l1FactoryBeacon;
    address internal l2FactoryBeacon;
    ERC20PeggedToken internal peggedImplL1;
    ERC20PeggedToken internal peggedImplL2;
    MockERC20Token internal originToken;

    function setUp() public {
        admin = address(this);
        relayer = makeAddr("relayer");
        l1Sender = makeAddr("l1Sender");
        l2Recipient = makeAddr("l2Recipient");
        l1Recipient = makeAddr("l1Recipient");

        string memory l1RpcUrlOrAlias = vm.envOr("L1_RPC_URL", string(""));
        string memory l2RpcUrlOrAlias = vm.envOr("L2_RPC_URL", string(""));
        if (bytes(l1RpcUrlOrAlias).length == 0 || bytes(l2RpcUrlOrAlias).length == 0) {
            vm.skip(true);
            return;
        }
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

        // L1 bridge
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
        l1Bridge.setExecuteGasLimit(2_000_000);

        // L1 ERC20 stack
        peggedImplL1 = new ERC20PeggedToken();
        ERC20TokenFactory fImpl = new ERC20TokenFactory();
        ERC1967Proxy fProxy = new ERC1967Proxy(address(fImpl), abi.encodeCall(ERC20TokenFactory.initialize, (admin, address(peggedImplL1))));
        l1Factory = ERC20TokenFactory(payable(address(fProxy)));
        l1FactoryBeacon = l1Factory.beacon();

        ERC20Gateway gImpl = new ERC20Gateway();
        ERC1967Proxy gProxy = new ERC1967Proxy(
            address(gImpl),
            abi.encodeCall(ERC20Gateway.initialize, (admin, address(l1Bridge), address(l1Factory)))
        );
        l1Gateway = ERC20Gateway(payable(address(gProxy)));
        l1Factory.setPaymentGateway(address(l1Gateway));

        originToken = new MockERC20Token("Mock Token", "MOCK", 1_000_000 ether, l1Sender);
    }

    function _deployOnL2() internal {
        _selectL2();

        l2BlockOracle = new L1BlockOracle(address(this));
        l2GasOracle = new L1GasOracle(relayer);

        FluentBridgeStorageLayout.InitConfiguration memory params = FluentBridgeStorageLayout.InitConfiguration({
            adminRole: admin,
            pauserRole: admin,
            relayerRole: relayer,
            otherBridge: address(0xB2)
        });

        // L2 bridge
        L2FluentBridge bridgeImpl = new L2FluentBridge();
        ERC1967Proxy bridgeProxy = new ERC1967Proxy(
            address(bridgeImpl),
            abi.encodeCall(
                L2FluentBridge.initialize,
                (abi.encode(params), RECEIVE_DEADLINE, address(l2BlockOracle), address(l2GasOracle), 0, 0, 0, makeAddr("feeTreasury"))
            )
        );
        l2Bridge = L2FluentBridge(payable(address(bridgeProxy)));
        l2Bridge.setExecuteGasLimit(2_000_000);

        // L2 ERC20 stack
        peggedImplL2 = new ERC20PeggedToken();
        ERC20TokenFactory fImpl = new ERC20TokenFactory();
        ERC1967Proxy fProxy = new ERC1967Proxy(address(fImpl), abi.encodeCall(ERC20TokenFactory.initialize, (admin, address(peggedImplL2))));
        l2Factory = ERC20TokenFactory(payable(address(fProxy)));
        l2FactoryBeacon = l2Factory.beacon();

        ERC20Gateway gImpl = new ERC20Gateway();
        ERC1967Proxy gProxy = new ERC1967Proxy(
            address(gImpl),
            abi.encodeCall(ERC20Gateway.initialize, (admin, address(l2Bridge), address(l2Factory)))
        );
        l2Gateway = ERC20Gateway(payable(address(gProxy)));
        l2Factory.setPaymentGateway(address(l2Gateway));
    }

    function _linkCrossChain() internal {
        _selectL1();
        l1Bridge.setOtherBridge(address(l2Bridge));
        l1Gateway.setOtherSide(false, address(l2Gateway), l2ChainId, address(peggedImplL2), address(l2Factory), l2FactoryBeacon);

        _selectL2();
        l2Bridge.setOtherBridge(address(l1Bridge));
        l2Gateway.setOtherSide(false, address(l1Gateway), l1ChainId, address(peggedImplL1), address(l1Factory), l1FactoryBeacon);
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

    function _decodeBridgeSentMessage(
        Vm.Log[] memory logs,
        address bridgeAddress
    )
        internal
        pure
        returns (
            address from,
            address to,
            uint256 value,
            uint256 chainId,
            uint256 blockNumber,
            uint256 nonce,
            bytes32 messageHash,
            bytes memory data
        )
    {
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != bridgeAddress || entry.topics.length != 3 || entry.topics[0] != SENT_MESSAGE_SIG) continue;
            from = address(uint160(uint256(entry.topics[1])));
            to = address(uint160(uint256(entry.topics[2])));
            (value, chainId, blockNumber, nonce, messageHash, data) = abi.decode(
                entry.data,
                (uint256, uint256, uint256, uint256, bytes32, bytes)
            );
            return (from, to, value, chainId, blockNumber, nonce, messageHash, data);
        }
        revert("SentMessage log not found");
    }

    /// @param withdrawalLeaves Real message hashes for this L2 block (from `SentMessage` / rollback), in tree order.
    function _finalizeSingleBlockBatch(bytes32[] memory withdrawalLeaves) internal returns (uint256 batchIndex, L2BlockHeader memory header) {
        _selectL1();
        bytes32 withdrawalRoot = WithdrawalMerkle.withdrawalRoot(withdrawalLeaves);
        batchIndex = l1Rollup.nextBatchIndex();
        header = L2BlockHeader({
            previousBlockHash: GENESIS_HASH,
            blockHash: keccak256(abi.encodePacked("erc20-flow", withdrawalRoot)),
            withdrawalRoot: withdrawalRoot,
            depositRoot: ZERO_BYTES_HASH,
            depositCount: 0
        });
        L2BlockHeader[] memory headers = new L2BlockHeader[](1);
        headers[0] = header;
        vm.prank(relayer);
        l1Rollup.acceptNextBatch(headers, 1);
        bytes32[] memory blobHashes = new bytes32[](1);
        blobHashes[0] = keccak256(abi.encode("erc20-flow-blob", batchIndex));
        vm.blobhashes(blobHashes);
        vm.prank(relayer);
        l1Rollup.submitBlobs(batchIndex, 1);
        vm.prank(relayer);
        l1Rollup.preconfirmBatch(address(l1NitroVerifier), batchIndex, DUMMY_SIGNATURE);
        vm.roll(block.number + FINALIZATION_DELAY + 2);
        l1Rollup.finalizeBatches(batchIndex);
        require(l1Rollup.isBatchFinalized(batchIndex), "batch not finalized");
    }

    /// @dev Finalize with `withdrawalRoot` from the real L2→L1 message hash only, then `receiveMessageWithProof`.
    function _receiveErc20WithProof(
        bytes32 messageHash,
        address from2,
        address to2,
        uint256 value2,
        uint256 chainId2,
        uint256 blockNumber2,
        uint256 nonce2,
        bytes memory data2,
        address caller
    ) internal {
        bytes32[] memory wl = WithdrawalMerkle.leavesSingleton(messageHash);
        (uint256 batchIndex, L2BlockHeader memory header) = _finalizeSingleBlockBatch(wl);
        _selectL1();
        vm.prank(caller);
        l1Bridge.receiveMessageWithProof(
            batchIndex,
            header,
            from2,
            payable(to2),
            value2,
            chainId2,
            blockNumber2,
            nonce2,
            data2,
            WithdrawalMerkle.proofForLeaf(wl, 0),
            MerkleTree.MerkleProof({nonce: 0, proof: ""})
        );
    }

    function test_sendTokens_roundtripL1ToL2AndBack() public {
        // L1 -> L2: lock origin, mint pegged.
        _selectL1();
        vm.prank(l1Sender);
        originToken.approve(address(l1Gateway), AMOUNT);
        vm.recordLogs();
        vm.prank(l1Sender);
        l1Gateway.sendTokens(address(originToken), l2Recipient, AMOUNT);
        assertEq(originToken.balanceOf(address(l1Gateway)), AMOUNT, "origin not locked");

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
        assertEq(value1, 0);
        address peggedOnL2 = l1Gateway.computeOtherSidePeggedTokenAddress(address(l2Gateway), address(originToken));

        _selectL2();

        vm.prank(relayer);
        l2Bridge.receiveMessage(from1, to1, value1, chainId1, blockNumber1, nonce1, data1);

        assertEq(IERC20(peggedOnL2).balanceOf(l2Recipient), AMOUNT, "pegged not minted");

        // L2 -> L1: burn pegged, unlock origin.
        _selectL2();
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
            ,
            bytes memory data2
        ) = _decodeBridgeSentMessage(vm.getRecordedLogs(), address(l2Bridge));
        _selectL1();
        uint256 before = originToken.balanceOf(l1Recipient);
        vm.prank(relayer);
        l1Bridge.receiveMessage(from2, to2, value2, chainId2, blockNumber2, nonce2, data2);
        assertEq(originToken.balanceOf(l1Recipient) - before, AMOUNT / 2, "origin not unlocked");
    }

    function test_receiveFailedMessage_retryUnlocksAfterRefund() public {
        // Prepare pegged on L2 by bridging L1->L2.
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
        uint256 backAmount = 40 ether;
        vm.prank(l2Recipient);
        IERC20(peggedOnL2).approve(address(l2Gateway), backAmount);
        vm.recordLogs();
        vm.prank(l2Recipient);
        l2Gateway.sendTokens(peggedOnL2, l1Recipient, backAmount);
        (
            address from2,
            address to2,
            uint256 value2,
            uint256 chainId2,
            uint256 blockNumber2,
            uint256 nonce2,
            bytes32 hash2,
            bytes memory data2
        ) = _decodeBridgeSentMessage(vm.getRecordedLogs(), address(l2Bridge));

        // Drain locked origin so first receiveOriginTokens attempt fails.
        _selectL1();
        vm.prank(address(l1Gateway));
        originToken.transfer(makeAddr("sink"), AMOUNT);

        vm.prank(relayer);
        l1Bridge.receiveMessage(from2, to2, value2, chainId2, blockNumber2, nonce2, data2);
        assertEq(uint256(l1Bridge.getReceivedMessage(hash2)), uint256(IFluentBridge.MessageStatus.Failed), "message should fail first");

        // Re-fund gateway and retry through receiveFailedMessage.
        vm.prank(l1Sender);
        originToken.transfer(address(l1Gateway), backAmount);
        uint256 before = originToken.balanceOf(l1Recipient);
        vm.prank(relayer);
        l1Bridge.receiveFailedMessage(from2, to2, value2, chainId2, blockNumber2, nonce2, data2);
        assertEq(originToken.balanceOf(l1Recipient) - before, backAmount, "retry did not unlock");
        assertEq(uint256(l1Bridge.getReceivedMessage(hash2)), uint256(IFluentBridge.MessageStatus.Success), "status not updated");
    }

    function test_rollbackMessageWithProof_timeoutMarksRollbackOnL1() public {
        // L1 send origin tokens to L2.
        _selectL1();
        vm.prank(l1Sender);
        originToken.approve(address(l1Gateway), AMOUNT);
        vm.recordLogs();
        vm.prank(l1Sender);
        l1Gateway.sendTokens(address(originToken), l2Recipient, AMOUNT);
        (address from, address to, uint256 value, , uint256 srcBlock, uint256 nonce, , bytes memory data) = _decodeBridgeSentMessage(
            vm.getRecordedLogs(),
            address(l1Bridge)
        );

        // L2: force deadline expiry and relay with L2 chain id to generate rollback hash.
        _selectL2();
        l2BlockOracle.updateL1BlockNumber(srcBlock + RECEIVE_DEADLINE + 1);
        bytes32 failedHash = _messageHash(from, to, value, l2ChainId, srcBlock, nonce, data);
        vm.prank(relayer);
        l2Bridge.receiveMessage(from, to, value, l2ChainId, srcBlock, nonce, data);
        assertEq(uint256(l2Bridge.getReceivedMessage(failedHash)), uint256(IFluentBridge.MessageStatus.Failed), "not failed on L2");

        // L1: finalize proof batch and call rollbackMessageWithProof.
        bytes32[] memory withdrawalLeaves = WithdrawalMerkle.leavesSingleton(failedHash);
        (uint256 batchIndex, L2BlockHeader memory header) = _finalizeSingleBlockBatch(withdrawalLeaves);
        MerkleTree.MerkleProof memory withdrawalProof = WithdrawalMerkle.proofForLeaf(withdrawalLeaves, 0);
        MerkleTree.MerkleProof memory blockProof = MerkleTree.MerkleProof({nonce: 0, proof: ""});
        vm.prank(relayer);
        l1Bridge.rollbackMessageWithProof(batchIndex, header, from, to, value, l2ChainId, srcBlock, nonce, data, withdrawalProof, blockProof);
        assertEq(uint256(l1Bridge.getRollbackMessage(failedHash)), uint256(IFluentBridge.MessageStatus.Failed), "rollback status mismatch");
        // ERC20 flow keeps tokens locked in gateway; rollback only marks bridge-level rollback status.
        assertEq(originToken.balanceOf(address(l1Gateway)), AMOUNT, "locked origin balance changed");
    }

    function test_RevertIf_sendTokens_otherSideNotSet() public {
        _selectL1();
        ERC20Gateway gImpl = new ERC20Gateway();
        ERC1967Proxy gProxy = new ERC1967Proxy(
            address(gImpl),
            abi.encodeCall(ERC20Gateway.initialize, (admin, address(l1Bridge), address(l1Factory)))
        );
        ERC20Gateway unconfiguredGateway = ERC20Gateway(payable(address(gProxy)));

        vm.prank(l1Sender);
        originToken.approve(address(unconfiguredGateway), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IGatewayBaseErrors.ZeroAddressNotAllowed.selector, "getOtherSideGateway"));
        vm.prank(l1Sender);
        unconfiguredGateway.sendTokens(address(originToken), l2Recipient, 1 ether);
    }

    function test_RevertIf_receiveOriginTokens_zeroRecipient() public {
        _selectL1();
        vm.mockCall(address(l1Bridge), abi.encodeCall(IFluentBridge.getNativeSender, ()), abi.encode(address(l2Gateway)));
        vm.expectRevert(IGatewayBaseErrors.InvalidRecipient.selector);
        vm.prank(address(l1Bridge));
        l1Gateway.receiveOriginTokens(address(originToken), l1Sender, address(0), 1 ether);
    }
}
