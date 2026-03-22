// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ExcessivelySafeCall} from "../../contracts/libraries/ExcessivelySafeCall.sol";

contract ReturnBombTarget {
    function bomb() external pure returns (bytes memory) {
        return new bytes(2048);
    }
}

contract RevertTarget {
    function fail() external pure {
        revert("always-fail");
    }
}

contract ExcessivelySafeCallHarness {
    function callTarget(
        address target, uint256 value, bytes memory data, uint256 gasLimit
    ) external returns (bool success, bytes memory returnData) {
        return ExcessivelySafeCall.excessivelySafeCall(target, value, data, gasLimit);
    }

    receive() external payable {}
}

contract ExcessivelySafeCallTest is Test {
    ExcessivelySafeCallHarness internal harness;

    function setUp() public {
        harness = new ExcessivelySafeCallHarness();
    }

    function test_excessivelySafeCall_truncatesLargeReturnData() public {
        ReturnBombTarget target = new ReturnBombTarget();
        (bool success, bytes memory data) = harness.callTarget(
            address(target), 0, abi.encodeCall(ReturnBombTarget.bomb, ()), gasleft()
        );
        assertTrue(success, "call should succeed");
        assertLe(data.length, 1024, "return data should be truncated to 1024");
    }

    function test_excessivelySafeCall_failedCallReturnsFalse() public {
        RevertTarget target = new RevertTarget();
        (bool success,) = harness.callTarget(
            address(target), 0, abi.encodeCall(RevertTarget.fail, ()), gasleft()
        );
        assertFalse(success, "call should fail");
    }

    function test_excessivelySafeCall_emptyTargetSucceeds() public {
        address eoa = makeAddr("eoa");
        (bool success,) = harness.callTarget(eoa, 0, "", gasleft());
        assertTrue(success, "call to EOA should succeed");
    }
}
