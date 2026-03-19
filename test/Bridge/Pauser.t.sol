// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {FluentBridgeStorageLayout} from "../../contracts/bridge/FluentBridgeStorageLayout.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {L2BlockHeader} from "../../contracts/interfaces/IRollupTypes.sol";

contract BridgePauserTest is Test {
    address internal admin;
    address internal pauser;
    address internal relayer;

    L1FluentBridge internal l1Bridge;
    L2FluentBridge internal l2Bridge;

    function setUp() public {
        admin = makeAddr("admin");
        pauser = makeAddr("pauser");
        relayer = makeAddr("relayer");

        FluentBridgeStorageLayout.InitConfiguration memory cfg = FluentBridgeStorageLayout.InitConfiguration({
            adminRole: admin,
            pauserRole: pauser,
            relayerRole: relayer,
            otherBridge: makeAddr("otherBridge")
        });

        L1FluentBridge l1Impl = new L1FluentBridge();
        ERC1967Proxy l1Proxy = new ERC1967Proxy(
            address(l1Impl),
            abi.encodeCall(L1FluentBridge.initialize, (abi.encode(cfg), makeAddr("rollupA")))
        );
        l1Bridge = L1FluentBridge(payable(address(l1Proxy)));

        L2FluentBridge l2Impl = new L2FluentBridge();
        ERC1967Proxy l2Proxy = new ERC1967Proxy(
            address(l2Impl),
            abi.encodeCall(L2FluentBridge.initialize, (abi.encode(cfg), 100, makeAddr("l1BlockOracleA")))
        );
        l2Bridge = L2FluentBridge(payable(address(l2Proxy)));
    }

    function _pauseBoth() internal {
        vm.prank(pauser);
        l1Bridge.pause();
        vm.prank(pauser);
        l2Bridge.pause();
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

    function test_pauser_can_pause_and_unpause() public {
        vm.prank(pauser);
        l1Bridge.pause();
        assertTrue(l1Bridge.paused());

        vm.prank(pauser);
        l1Bridge.unpause();
        assertTrue(!l1Bridge.paused());
    }

    function test_sendMessage_reverts_when_paused_on_l1_and_l2() public {
        _pauseBoth();

        vm.expectRevert();
        l1Bridge.sendMessage(makeAddr("dst1"), hex"1234");

        vm.expectRevert();
        l2Bridge.sendMessage(makeAddr("dst2"), hex"5678");
    }

    function test_receiveMessage_reverts_when_paused_on_l1_and_l2() public {
        _pauseBoth();

        vm.expectRevert();
        vm.prank(relayer);
        l1Bridge.receiveMessage(makeAddr("from"), payable(makeAddr("to")), 0, 1, 1, 0, "");

        vm.expectRevert();
        vm.prank(relayer);
        l2Bridge.receiveMessage(makeAddr("from"), payable(makeAddr("to")), 0, 1, 1, 0, "");
    }

    function test_receiveFailedMessage_reverts_when_paused_on_l1_and_l2() public {
        _pauseBoth();

        vm.expectRevert();
        l1Bridge.receiveFailedMessage(makeAddr("from"), payable(makeAddr("to")), 0, 1, 1, 0, "");

        vm.expectRevert();
        l2Bridge.receiveFailedMessage(makeAddr("from"), payable(makeAddr("to")), 0, 1, 1, 0, "");
    }

    function test_l1_proof_flows_revert_when_paused() public {
        vm.prank(pauser);
        l1Bridge.pause();

        L2BlockHeader memory header = _dummyHeader();
        MerkleTree.MerkleProof memory withdrawalProof = _dummyProof();
        MerkleTree.MerkleProof memory blockProof = _dummyProof();

        vm.expectRevert();
        l1Bridge.receiveMessageWithProof(0, header, makeAddr("from"), payable(makeAddr("to")), 0, 1, 1, 0, "", withdrawalProof, blockProof);

        vm.expectRevert();
        l1Bridge.rollbackMessageWithProof(0, header, makeAddr("from"), makeAddr("to"), 0, 1, 1, 0, "", withdrawalProof, blockProof);
    }

    function test_sendMessage_works_again_after_unpause() public {
        vm.prank(pauser);
        l2Bridge.pause();

        vm.expectRevert();
        l2Bridge.sendMessage(makeAddr("dst"), hex"01");

        vm.prank(pauser);
        l2Bridge.unpause();

        l2Bridge.sendMessage(makeAddr("dst"), hex"01");
        assertEq(l2Bridge.getNonce(), 1);
    }
}
