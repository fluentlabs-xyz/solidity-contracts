// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {StdInvariant} from "forge-std/StdInvariant.sol";

import {GatewayBase} from "../Gateway/Base.t.sol";
import {BridgeGatewayHandler} from "./BridgeGatewayHandler.sol";

contract BridgeGatewayInvariantTest is StdInvariant, GatewayBase {
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
