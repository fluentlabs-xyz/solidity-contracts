// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ERC1155TokenFactory} from "../../contracts/factories/ERC1155TokenFactory.sol";
import {ERC1155PeggedToken} from "../../contracts/tokens/ERC1155PeggedToken.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys ERC1155TokenFactory: pegged token impl + beacon + factory UUPS proxy.
/// @dev Inherit and call _deployERC1155Factory() inside your broadcast.
contract DeployERC1155Factory is DeployBase {
    struct ERC1155FactoryResult {
        address factory;
        address factoryImpl;
        address factoryBeacon;
        address peggedImpl;
    }

    function _deployERC1155Factory(address initialOwner) internal returns (ERC1155FactoryResult memory r) {
        r.peggedImpl = address(new ERC1155PeggedToken());
        r.factory = Upgrades.deployUUPSProxy(
            "ERC1155TokenFactory.sol:ERC1155TokenFactory",
            abi.encodeCall(ERC1155TokenFactory.initialize, (initialOwner, r.peggedImpl))
        );
        r.factoryImpl = Upgrades.getImplementationAddress(r.factory);
        r.factoryBeacon = ERC1155TokenFactory(r.factory).beacon();
    }

    /// @dev Standalone: INITIAL_OWNER required.
    function run() external virtual {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying ERC1155TokenFactory");
        console2.log("  initialOwner:", initialOwner);

        vm.startBroadcast();
        ERC1155FactoryResult memory r = _deployERC1155Factory(initialOwner);
        vm.stopBroadcast();

        console2.log("ERC1155TokenFactory deployed:", r.factory);
        console2.log("  impl:", r.factoryImpl);
        console2.log("  beacon:", r.factoryBeacon);
        console2.log("  peggedImpl:", r.peggedImpl);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "erc1155_factory", r.factory);
            out = vm.serializeAddress("deployment", "erc1155_factory_impl", r.factoryImpl);
            out = vm.serializeAddress("deployment", "erc1155_factory_beacon", r.factoryBeacon);
            out = vm.serializeAddress("deployment", "erc1155_pegged_impl", r.peggedImpl);
            vm.writeJson(out, outputPath);
        }
    }
}
