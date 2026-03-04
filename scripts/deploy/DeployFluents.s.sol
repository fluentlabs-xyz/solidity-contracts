// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseScript} from "../Base.sol";
import {FluentBridge} from "../../contracts/FluentBridge.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployFluents is BaseScript {
    event BridgeDeployed(address indexed implementation, address indexed proxy);

    function run() external returns (address bridgeProxy) {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        address bridgeAuthority = vm.envOr("BRIDGE_AUTHORITY", initialOwner);
        uint256 receiveMessageDeadline = vm.envOr("RECEIVE_MSG_DEADLINE", uint256(0));
        address otherBridgePlaceholder = vm.envOr("OTHER_BRIDGE_PLACEHOLDER", address(0x1));
        address l1BlockOracle = vm.envOr("L1_BLOCK_ORACLE", address(0));
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        vm.startBroadcast();

        FluentBridge bridgeImpl = new FluentBridge();
        ERC1967Proxy bridgeProxyContract = new ERC1967Proxy(
            address(bridgeImpl),
            abi.encodeCall(
                FluentBridge.initialize,
                (
                    initialOwner,
                    bridgeAuthority,
                    address(0),
                    receiveMessageDeadline,
                    otherBridgePlaceholder,
                    l1BlockOracle
                )
            )
        );

        vm.stopBroadcast();

        bridgeProxy = address(bridgeProxyContract);
        emit BridgeDeployed(address(bridgeImpl), bridgeProxy);

        if (bytes(outputPath).length != 0) {
            string memory json = vm.serializeAddress("deployment", "bridge_impl", address(bridgeImpl));
            json = vm.serializeAddress("deployment", "bridge", bridgeProxy);
            vm.writeJson(json, outputPath);
        }
    }
}
