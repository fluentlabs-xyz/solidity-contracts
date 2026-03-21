// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockNitroVerifier} from "./mocks/MockNitroVerifier.sol";
import {L2BlockHeader} from "../../contracts/interfaces/IRollupTypes.sol";
import {BatchStatus} from "../../contracts/interfaces/IRollupTypes.sol";

import {RollupBase} from "./Base.t.sol";

/**
 * @notice Covers Rollup._checkDeposits by feeding multiple L1 deposits into acceptNextBatch.
 */
contract DepositsTest is RollupBase {
    bytes32[3] internal _depositIds = [
        keccak256("deposit-0"),
        keccak256("deposit-1"),
        keccak256("deposit-2")
    ];

    bytes32 internal _depositRoot;
    uint256 internal _depositCount = 3;

    MockL1DepositsBridge internal depositsBridge;

    function setUp() public override {
        depositsBridge = new MockL1DepositsBridge(_depositIds);
        bridgeAddr = address(depositsBridge);
        nitroVerifier = new MockNitroVerifier();
        rollup = _deployRollup(bridgeAddr);

        bytes32[] memory ids = new bytes32[](3);
        ids[0] = _depositIds[0];
        ids[1] = _depositIds[1];
        ids[2] = _depositIds[2];
        _depositRoot = keccak256(abi.encodePacked(ids));
    }

    function test_acceptNextBatch_checksDeposits_forMultipleDeposits() public {
        L2BlockHeader[] memory batch = _makeBatch(GENESIS_HASH);

        // Trigger _checkDeposits for exactly one header (batch header index 0).
        batch[0].depositRoot = _depositRoot;
        batch[0].depositCount = _depositCount;

        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 0);

        assertEq(uint8(rollup.getBatch(1).status), uint8(BatchStatus.HeadersSubmitted));
        assertEq(depositsBridge.poppedCount(), _depositCount, "not all deposits were popped");
    }
}

contract MockL1DepositsBridge {
    bytes32[3] internal _ids;
    uint256 internal _idx;

    constructor(bytes32[3] memory ids) {
        _ids = ids;
        _idx = 0;
    }

    // Called by Rollup._checkDeposits.
    function popSentMessage() external returns (bytes32, uint256) {
        require(_idx < _ids.length, "deposits queue empty");
        bytes32 id = _ids[_idx];
        _idx++;
        return (id, block.number);
    }

    function poppedCount() external view returns (uint256) {
        return _idx;
    }
}

