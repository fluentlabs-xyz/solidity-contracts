// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys ERC20TokenFactory (L1): pegged token impl + beacon + factory UUPS proxy.
/// @dev Inherit and call _deployERC20Factory() inside your broadcast.
contract DeployERC20Factory is DeployBase {
    struct ERC20FactoryResult {
        address factory;
        address factoryImpl;
        address factoryBeacon;
        address peggedImpl;
    }

    function _deployERC20Factory(address initialOwner) internal returns (ERC20FactoryResult memory r) {
        r.peggedImpl = address(new ERC20PeggedToken());
        r.factory = Upgrades.deployUUPSProxy(
            "ERC20TokenFactory.sol:ERC20TokenFactory",
            abi.encodeCall(ERC20TokenFactory.initialize, (initialOwner, r.peggedImpl))
        );
        r.factoryImpl = Upgrades.getImplementationAddress(r.factory);
        r.factoryBeacon = ERC20TokenFactory(r.factory).beacon();
    }

    /// @dev Standalone: INITIAL_OWNER required.
    function run() external virtual {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying ERC20TokenFactory");
        console2.log("  initialOwner:", initialOwner);

        vm.startBroadcast();
        ERC20FactoryResult memory r = _deployERC20Factory(initialOwner);
        vm.stopBroadcast();

        console2.log("ERC20TokenFactory deployed:", r.factory);
        console2.log("  impl:", r.factoryImpl);
        console2.log("  beacon:", r.factoryBeacon);
        console2.log("  peggedImpl:", r.peggedImpl);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "factory", r.factory);
            out = vm.serializeAddress("deployment", "factory_impl", r.factoryImpl);
            out = vm.serializeAddress("deployment", "factory_beacon", r.factoryBeacon);
            out = vm.serializeAddress("deployment", "pegged_impl", r.peggedImpl);
            vm.writeJson(out, outputPath);
        }
    }
}
