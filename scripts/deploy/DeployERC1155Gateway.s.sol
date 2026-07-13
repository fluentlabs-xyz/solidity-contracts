// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ERC1155Gateway} from "../../contracts/gateways/ERC1155Gateway.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys ERC1155Gateway behind a UUPS proxy.
/// @dev Inherit and call _deployERC1155Gateway() inside your broadcast.
contract DeployERC1155Gateway is DeployBase {
    struct ERC1155GatewayResult {
        address gateway;
        address gatewayImpl;
    }

    function _deployERC1155Gateway(address initialOwner, address bridgeAddress, address factoryAddress)
        internal
        returns (ERC1155GatewayResult memory r)
    {
        r.gateway = Upgrades.deployUUPSProxy(
            "ERC1155Gateway.sol:ERC1155Gateway",
            abi.encodeCall(ERC1155Gateway.initialize, (initialOwner, bridgeAddress, factoryAddress))
        );
        r.gatewayImpl = Upgrades.getImplementationAddress(r.gateway);
    }

    /// @dev Standalone: INITIAL_OWNER, BRIDGE_ADDRESS, FACTORY_ADDRESS required.
    function run() external virtual {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        address bridge = vm.envAddress("BRIDGE_ADDRESS");
        address factory = vm.envAddress("FACTORY_ADDRESS");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying ERC1155Gateway");
        console2.log("  initialOwner:", initialOwner);
        console2.log("  bridge:", bridge);
        console2.log("  factory:", factory);

        vm.startBroadcast();
        ERC1155GatewayResult memory r = _deployERC1155Gateway(initialOwner, bridge, factory);
        vm.stopBroadcast();

        console2.log("ERC1155Gateway deployed:", r.gateway);
        console2.log("  impl:", r.gatewayImpl);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "erc1155_gateway", r.gateway);
            out = vm.serializeAddress("deployment", "erc1155_gateway_impl", r.gatewayImpl);
            vm.writeJson(out, outputPath);
        }
    }
}
