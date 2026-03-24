// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";

import {DeployLib} from "./DeployLib.s.sol";

/**
 * @notice Deploy only the L2 FluentBridge (UUPS proxy + implementation).
 * @dev Reads chain config from scripts/input/<NETWORK>.json. Env vars override JSON values.
 *      L1 gas price oracle: {DeployLib} auto-deploys {L1GasOracle} (submitter = relayer) and wires it into {L2FluentBridge}.
 *      Requires ALLOW_UNSAFE_UPGRADES=true.
 */
contract DeployL2FluentBridge is DeployLib {
    using stdJson for string;

    function run() external returns (address bridgeProxy) {
        string memory network = vm.envOr("NETWORK", string("testnet/l2"));
        string memory json = _readConfig(network);
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        address adminRole = vm.envOr("ADMIN_ROLE", json.readAddress(".roles.admin"));
        require(adminRole != address(0), "ADMIN_ROLE required");

        address pauserRole = vm.envOr("PAUSER_ROLE", json.readAddress(".roles.pauser"));
        address relayerRole = vm.envOr("RELAYER_ROLE", json.readAddress(".roles.relayer"));
        address otherBridgePlaceholder = vm.envOr("OTHER_BRIDGE_PLACEHOLDER", address(0x1));
        uint256 receiveMessageDeadline = vm.envOr("RECEIVE_MSG_DEADLINE", json.readUint(".bridge.receiveMessageDeadline"));
        require(receiveMessageDeadline != 0, "RECEIVE_MSG_DEADLINE required");
        address l1BlockOracle = vm.envAddress("L1_BLOCK_ORACLE");

        vm.startBroadcast();
        address bridgeImpl;
        (bridgeProxy, bridgeImpl) = _deployFluentBridge(
            adminRole,
            pauserRole,
            relayerRole,
            receiveMessageDeadline,
            otherBridgePlaceholder,
            l1BlockOracle,
            address(0)
        );
        vm.stopBroadcast();

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "bridge_impl", bridgeImpl);
            out = vm.serializeAddress("deployment", "bridge", bridgeProxy);
            vm.writeJson(out, outputPath);
        }
    }
}
