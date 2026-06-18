// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ERC721Gateway} from "../../contracts/gateways/ERC721Gateway.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys ERC721Gateway behind a UUPS proxy.
/// @dev Inherit and call _deployERC721Gateway() inside your broadcast.
contract DeployERC721Gateway is DeployBase {
    struct ERC721GatewayResult {
        address gateway;
        address gatewayImpl;
    }

    function _deployERC721Gateway(address initialOwner, address bridgeAddress, address factoryAddress)
        internal
        returns (ERC721GatewayResult memory r)
    {
        r.gateway = Upgrades.deployUUPSProxy(
            "ERC721Gateway.sol:ERC721Gateway",
            abi.encodeCall(ERC721Gateway.initialize, (initialOwner, bridgeAddress, factoryAddress))
        );
        r.gatewayImpl = Upgrades.getImplementationAddress(r.gateway);
    }

    /// @dev Standalone: INITIAL_OWNER, BRIDGE_ADDRESS, FACTORY_ADDRESS required.
    function run() external virtual {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        address bridge = vm.envAddress("BRIDGE_ADDRESS");
        address factory = vm.envAddress("FACTORY_ADDRESS");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying ERC721Gateway");
        console2.log("  initialOwner:", initialOwner);
        console2.log("  bridge:", bridge);
        console2.log("  factory:", factory);

        vm.startBroadcast();
        ERC721GatewayResult memory r = _deployERC721Gateway(initialOwner, bridge, factory);
        vm.stopBroadcast();

        console2.log("ERC721Gateway deployed:", r.gateway);
        console2.log("  impl:", r.gatewayImpl);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "erc721_gateway", r.gateway);
            out = vm.serializeAddress("deployment", "erc721_gateway_impl", r.gatewayImpl);
            vm.writeJson(out, outputPath);
        }
    }
}
