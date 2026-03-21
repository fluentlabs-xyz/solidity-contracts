// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {FluentBridgeStorageLayout} from "../../contracts/bridge/FluentBridgeStorageLayout.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {L2BlockHeader} from "../../contracts/interfaces/IRollupTypes.sol";

contract RollupMock {
    bool public finalized;

    function setFinalized(bool value) external {
        finalized = value;
    }

    function isBatchFinalized(uint256) external view returns (bool) {
        return finalized;
    }
}

contract L1FluentBridgeTest is Test {
    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal relayer = makeAddr("relayer");
    address internal otherBridge = makeAddr("otherBridge");
    address internal user = makeAddr("user");
    address internal receiver = makeAddr("receiver");
    address internal nonRollup = makeAddr("nonRollup");

    RollupMock internal rollup;
    L1FluentBridge internal l1Bridge;

    function setUp() public {
        rollup = new RollupMock();

        FluentBridgeStorageLayout.InitConfiguration memory cfg = FluentBridgeStorageLayout.InitConfiguration({
            adminRole: admin,
            pauserRole: pauser,
            relayerRole: relayer,
            otherBridge: otherBridge
        });

        L1FluentBridge impl = new L1FluentBridge();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(L1FluentBridge.initialize, (abi.encode(cfg), address(rollup))));
        l1Bridge = L1FluentBridge(payable(address(proxy)));
    }

    function _dummyHeader() internal pure returns (L2BlockHeader memory header) {
        header = L2BlockHeader({
            previousBlockHash: bytes32(uint256(1)),
            blockHash: bytes32(uint256(2)),
            withdrawalRoot: bytes32(uint256(3)),
            depositRoot: bytes32(uint256(4)),
            depositCount: 0
        });
    }

    function _dummyProof() internal pure returns (MerkleTree.MerkleProof memory proof) {
        proof = MerkleTree.MerkleProof({nonce: 0, proof: ""});
    }

    function test_sendMessage_enqueues_and_rollup_can_pop() public {
        l1Bridge.sendMessage(receiver, hex"0102");

        vm.prank(address(rollup));
        (bytes32 msgHash, ) = l1Bridge.popSentMessage();

        assertTrue(msgHash != bytes32(0), "message hash should be queued");

        // Queue should now be empty.
        vm.prank(address(rollup));
        vm.expectRevert();
        l1Bridge.popSentMessage();
    }

    function test_popSentMessage_reverts_for_non_rollup() public {
        vm.prank(nonRollup);
        vm.expectRevert();
        l1Bridge.popSentMessage();
    }

    function test_setRollup_reverts_when_queue_not_empty() public {
        l1Bridge.sendMessage(receiver, hex"deadbeef");

        vm.prank(admin);
        vm.expectRevert();
        l1Bridge.setRollup(makeAddr("nextRollup"));
    }

    function test_receiveMessageWithProof_reverts_when_batch_not_finalized() public {
        rollup.setFinalized(false);

        vm.expectRevert();
        l1Bridge.receiveMessageWithProof(
            7,
            _dummyHeader(),
            user,
            payable(receiver),
            0,
            block.chainid + 1,
            1,
            0,
            "",
            _dummyProof(),
            _dummyProof()
        );
    }

    function test_receiveMessageWithProof_reverts_when_source_chain_is_local() public {
        rollup.setFinalized(true);

        vm.expectRevert();
        l1Bridge.receiveMessageWithProof(1, _dummyHeader(), user, payable(receiver), 0, block.chainid, 1, 0, "", _dummyProof(), _dummyProof());
    }

    function test_rollbackMessageWithProof_reverts_when_batch_not_finalized() public {
        rollup.setFinalized(false);

        vm.expectRevert();
        l1Bridge.rollbackMessageWithProof(3, _dummyHeader(), user, receiver, 0, block.chainid + 1, 1, 0, "", _dummyProof(), _dummyProof());
    }

    function test_rollbackMessageWithProof_reverts_when_source_chain_is_local() public {
        rollup.setFinalized(true);

        vm.expectRevert();
        l1Bridge.rollbackMessageWithProof(3, _dummyHeader(), user, receiver, 0, block.chainid, 1, 0, "", _dummyProof(), _dummyProof());
    }
}
