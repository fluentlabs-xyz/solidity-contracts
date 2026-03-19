// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {StdInvariant} from "forge-std/StdInvariant.sol";

import {BridgeGatewayBase} from "../Bridge/Base.t.sol";
import {BridgeGatewayHandler} from "./BridgeGatewayHandler.t.sol";

contract BridgeGatewayInvariantTest is StdInvariant, BridgeGatewayBase {
    BridgeGatewayHandler internal handler;

    function setUp() public override {
        super.setUp();
        _deployBridge(0);
        _deployGatewayStack();

        handler = new BridgeGatewayHandler(bridge, gateway, originToken, relayer, remoteGateway, user);
        targetContract(address(handler));
    }

    function invariant_nativeSenderIsAlwaysClearedOutsideExecution() public view {
        assertEq(bridge.getNativeSender(), address(0));
    }

    function invariant_registeredPeggedTokenMappingRemainsConsistent() public view {
        address predictedPegged = _predictedPegged();
        address mappedOrigin = gateway.getTokenMapping(predictedPegged);

        if (mappedOrigin != address(0)) {
            assertEq(mappedOrigin, address(originToken));
            assertGt(predictedPegged.code.length, 0);
        }
    }
}
