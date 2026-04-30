// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {FluentBridgeStorageLayout} from "../../contracts/bridge/FluentBridgeStorageLayout.sol";
import {L1BlockOracle} from "../../contracts/oracles/L1BlockOracle.sol";
import {L1GasOracle} from "../../contracts/oracles/L1GasOracle.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {L2BlockHeader} from "../../contracts/interfaces/rollup/IRollupTypes.sol";
import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";

contract NoopReceiver {
    uint256 public calls;

    /// @dev Allows native bridge delivery with empty calldata (gateway registration requires a contract).
    receive() external payable {}

    function handle() external payable {
        calls += 1;
    }
}

contract RevertingReceiver {
    function fail() external payable {
        revert("receiver-failed");
    }
}

contract RejectEther {
    receive() external payable {
        revert("reject-eth");
    }
}

abstract contract BridgeBase is Test {
    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal relayer = makeAddr("relayer");
    address internal stranger = makeAddr("stranger");

    L1FluentBridge internal l1Bridge;
    L2FluentBridge internal l2Bridge;

    function setUp() public virtual {
        IFluentBridge.InitConfiguration memory cfg = IFluentBridge.InitConfiguration({
            adminRole: admin,
            pauserRole: pauser,
            relayerRole: relayer,
            otherBridge: makeAddr("otherBridge")
        });

        L1FluentBridge l1Impl = new L1FluentBridge();
        ERC1967Proxy l1Proxy = new ERC1967Proxy(
            address(l1Impl),
            abi.encodeCall(L1FluentBridge.initialize, (abi.encode(cfg), makeAddr("rollupA"), 100, 100))
        );
        l1Bridge = L1FluentBridge(payable(address(l1Proxy)));

        L1BlockOracle l1BlockOracle = new L1BlockOracle(relayer);
        L1GasOracle l1GasOracle = new L1GasOracle(relayer);
        vm.prank(relayer);
        l1BlockOracle.updateL1BlockNumber(1);

        L2FluentBridge l2Impl = new L2FluentBridge();
        ERC1967Proxy l2Proxy = new ERC1967Proxy(
            address(l2Impl),
            abi.encodeCall(
                L2FluentBridge.initialize,
                (abi.encode(cfg), address(l1BlockOracle), address(l1GasOracle), 0, 0, 0, makeAddr("feeTreasury"))
            )
        );
        l2Bridge = L2FluentBridge(payable(address(l2Proxy)));
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

    /// @dev Register a gateway on the L1 bridge so both `sendMessage` and `_receiveMessage`
    ///      accept it. Idempotent — the admin setter has no "already registered" guard.
    function _registerOnL1Bridge(address target) internal {
        vm.prank(admin);
        (bool ok, ) = address(l1Bridge).call(abi.encodeWithSignature("registerGateway(address)", target));
        require(ok, "registerGateway (L1) failed");
    }

    /// @dev Register a gateway on the L2 bridge so both `sendMessage` and `_receiveMessage`
    ///      accept it. Idempotent — the admin setter has no "already registered" guard.
    function _registerOnL2Bridge(address target) internal {
        vm.prank(admin);
        (bool ok, ) = address(l2Bridge).call(abi.encodeWithSignature("registerGateway(address)", target));
        require(ok, "registerGateway (L2) failed");
    }

    function _dummyProof() internal pure returns (MerkleTree.MerkleProof memory proof) {
        proof = MerkleTree.MerkleProof({nonce: 0, proof: ""});
    }
}
