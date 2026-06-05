// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IFluentBridge, IFluentBridgeErrors} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {IGatewayBaseErrors} from "../../contracts/interfaces/gateways/IGatewayBase.sol";
import {IWasmGatewayErrors} from "../../contracts/interfaces/gateways/IWasmGateway.sol";
import {WasmGateway} from "../../contracts/gateways/WasmGateway.sol";
import {GatewayBase} from "./Base.t.sol";
import {MockWasmRuntime} from "../mocks/MockWasmRuntime.sol";

contract WasmGatewayTest is GatewayBase {
    WasmGateway internal wasmGateway;
    MockWasmRuntime internal runtime;

    function setUp() public override {
        super.setUp();
        _deployBridge(0);
        _deployWasmGateway();
    }

    function _deployWasmGateway() internal {
        runtime = new MockWasmRuntime();
        WasmGateway impl = new WasmGateway();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(WasmGateway.initialize, (admin, address(bridge), address(runtime)))
        );
        wasmGateway = WasmGateway(payable(address(proxy)));

        vm.prank(admin);
        wasmGateway.setOtherSideGateway(remoteGateway);

        _registerGateway(address(wasmGateway));
        _registerGateway(remoteGateway);
    }

    function test_initialize_setsDefaults() public view {
        assertEq(wasmGateway.owner(), admin);
        assertEq(wasmGateway.getBridgeContract(), address(bridge));
        assertEq(wasmGateway.getOtherSideGateway(), remoteGateway);
        assertEq(wasmGateway.getRuntime(), address(runtime));
    }

    function test_requestDeploy_sendsBridgeMessageAndLocksValue() public {
        bytes memory wasmBytecode = hex"0061736d";
        bytes memory constructorCalldata = abi.encode(uint256(42));
        uint256 value = 0.25 ether;
        vm.deal(user, value);

        vm.prank(user);
        wasmGateway.requestDeploy{value: value}(wasmBytecode, constructorCalldata);

        assertEq(address(bridge).balance, value);
    }

    function test_requestDeploy_revertsForEmptyBytecode() public {
        vm.prank(user);
        vm.expectRevert(IWasmGatewayErrors.EmptyWasmBytecode.selector);
        wasmGateway.requestDeploy("", "");
    }

    function test_requestDeploy_withoutOtherSideGateway_revertsOnUnregisteredDestination() public {
        WasmGateway impl = new WasmGateway();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(WasmGateway.initialize, (admin, address(bridge), address(runtime)))
        );
        WasmGateway localGateway = WasmGateway(payable(address(proxy)));

        vm.prank(user);
        vm.expectRevert(IFluentBridgeErrors.GatewayNotWhitelisted.selector);
        localGateway.requestDeploy(hex"0061736d", "");
    }

    function test_requestInvoke_sendsBridgeMessageAndLocksValue() public {
        address wasmContract = makeAddr("wasmContract");
        bytes memory calldataPayload = abi.encodeWithSignature("run(uint256)", 7);
        uint256 value = 0.1 ether;
        vm.deal(user, value);

        vm.prank(user);
        wasmGateway.requestInvoke{value: value}(wasmContract, calldataPayload);

        assertEq(address(bridge).balance, value);
    }

    function test_requestInvoke_revertsForZeroWasmContract() public {
        vm.prank(user);
        vm.expectRevert(IWasmGatewayErrors.InvalidWasmContract.selector);
        wasmGateway.requestInvoke(address(0), "");
    }

    function test_receiveDeployRequest_viaBridge_callsRuntime() public {
        bytes memory wasmBytecode = hex"0061736d01000000";
        bytes memory constructorCalldata = abi.encode("init");
        uint256 value = 0.4 ether;
        bytes memory message =
            abi.encodeCall(WasmGateway.receiveDeployRequest, (user, wasmBytecode, constructorCalldata));

        bytes32 messageHash = _relayWasmMessage(remoteGateway, address(wasmGateway), value, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(runtime.lastRequester(), user);
        assertEq(runtime.lastValue(), value);
        assertEq(runtime.lastWasmHash(), keccak256(wasmBytecode));
        assertEq(runtime.lastConstructorCalldata(), constructorCalldata);
    }

    function test_receiveInvokeRequest_viaBridge_callsRuntime() public {
        address wasmContract = makeAddr("wasmContract");
        bytes memory calldataPayload = abi.encodeWithSignature("run(bytes)", hex"1234");
        bytes memory expectedReturn = abi.encode(uint256(123));
        uint256 value = 0.05 ether;
        runtime.setNextInvokeReturnData(expectedReturn);
        bytes memory message = abi.encodeCall(WasmGateway.receiveInvokeRequest, (user, wasmContract, calldataPayload));

        bytes32 messageHash = _relayWasmMessage(remoteGateway, address(wasmGateway), value, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(runtime.lastRequester(), user);
        assertEq(runtime.lastWasmContract(), wasmContract);
        assertEq(runtime.lastValue(), value);
        assertEq(runtime.lastCalldataPayload(), calldataPayload);
    }

    function test_receiveRequest_fromWrongGateway_marksFailed() public {
        bytes memory message = abi.encodeCall(WasmGateway.receiveDeployRequest, (user, hex"0061736d", ""));

        bytes32 messageHash = _relayWasmMessage(makeAddr("wrongRemoteGateway"), address(wasmGateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_receiveDeployRequest_withoutRuntime_marksFailed() public {
        vm.prank(admin);
        wasmGateway.setRuntime(address(0));
        bytes memory message = abi.encodeCall(WasmGateway.receiveDeployRequest, (user, hex"0061736d", ""));

        bytes32 messageHash = _relayWasmMessage(remoteGateway, address(wasmGateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_receiveDeployRequest_runtimeRevert_marksFailed() public {
        runtime.setShouldRevert(true);
        bytes memory message = abi.encodeCall(WasmGateway.receiveDeployRequest, (user, hex"0061736d", ""));

        bytes32 messageHash = _relayWasmMessage(remoteGateway, address(wasmGateway), 0, message);

        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_receiveDeployRequest_directCall_reverts() public {
        vm.prank(user);
        vm.expectRevert(IGatewayBaseErrors.OnlyFluentBridge.selector);
        wasmGateway.receiveDeployRequest(user, hex"0061736d", "");
    }

    function _relayWasmMessage(address from, address to, uint256 value, bytes memory message)
        internal
        returns (bytes32 messageHash)
    {
        uint256 nonce = bridge.getReceivedNonce();
        uint256 sourceBlock = nextSourceBlock++;
        messageHash = _bridgeMessageHash(from, to, value, sourceChainId, sourceBlock, nonce, message);

        vm.deal(address(bridge), address(bridge).balance + value);
        vm.prank(relayer);
        bridge.receiveMessage(from, to, value, sourceChainId, sourceBlock, nonce, message);
    }
}
