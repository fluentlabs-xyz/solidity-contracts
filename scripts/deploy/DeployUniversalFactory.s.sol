// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys UniversalTokenFactory (L2) behind a UUPS proxy.
/// @dev Inherit and call _deployUniversalFactory() inside your broadcast.
contract DeployUniversalFactory is DeployBase {
    struct UniversalFactoryResult {
        address factory;
        address factoryImpl;
    }

    function _deployUniversalFactory(address initialOwner) internal returns (UniversalFactoryResult memory r) {
        r.factory = Upgrades.deployUUPSProxy(
            "UniversalTokenFactory.sol:UniversalTokenFactory",
            abi.encodeCall(UniversalTokenFactory.initialize, (initialOwner))
        );
        r.factoryImpl = Upgrades.getImplementationAddress(r.factory);
    }

    /// @dev Standalone: INITIAL_OWNER required.
    function run() external virtual {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying UniversalTokenFactory");
        console2.log("  initialOwner:", initialOwner);

        vm.startBroadcast();
        UniversalFactoryResult memory r = _deployUniversalFactory(initialOwner);
        vm.stopBroadcast();

        console2.log("UniversalTokenFactory deployed:", r.factory);
        console2.log("  impl:", r.factoryImpl);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "factory", r.factory);
            out = vm.serializeAddress("deployment", "factory_impl", r.factoryImpl);
            vm.writeJson(out, outputPath);
        }
    }
}
