// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys ERC20Gateway behind a UUPS proxy.
/// @dev Inherit and call _deployERC20Gateway() inside your broadcast.
contract DeployERC20Gateway is DeployBase {
    struct ERC20GatewayResult {
        address gateway;
        address gatewayImpl;
    }

    function _deployERC20Gateway(
        address initialOwner,
        address bridgeAddress,
        address factoryAddress
    ) internal returns (ERC20GatewayResult memory r) {
        r.gateway = Upgrades.deployUUPSProxy(
            "ERC20Gateway.sol:ERC20Gateway",
            abi.encodeCall(ERC20Gateway.initialize, (initialOwner, bridgeAddress, factoryAddress))
        );
        r.gatewayImpl = Upgrades.getImplementationAddress(r.gateway);
    }

    /// @dev Standalone: INITIAL_OWNER, BRIDGE_ADDRESS, FACTORY_ADDRESS required.
    function run() external virtual {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        address bridge = vm.envAddress("BRIDGE_ADDRESS");
        address factory = vm.envAddress("FACTORY_ADDRESS");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying ERC20Gateway");
        console2.log("  initialOwner:", initialOwner);
        console2.log("  bridge:", bridge);
        console2.log("  factory:", factory);

        vm.startBroadcast();
        ERC20GatewayResult memory r = _deployERC20Gateway(initialOwner, bridge, factory);
        vm.stopBroadcast();

        console2.log("ERC20Gateway deployed:", r.gateway);
        console2.log("  impl:", r.gatewayImpl);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "erc20_gateway", r.gateway);
            out = vm.serializeAddress("deployment", "erc20_gateway_impl", r.gatewayImpl);
            vm.writeJson(out, outputPath);
        }
    }
}
