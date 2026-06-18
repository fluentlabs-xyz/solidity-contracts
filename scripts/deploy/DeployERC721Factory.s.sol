// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ERC721TokenFactory} from "../../contracts/factories/ERC721TokenFactory.sol";
import {ERC721PeggedToken} from "../../contracts/tokens/ERC721PeggedToken.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys ERC721TokenFactory: pegged token impl + beacon + factory UUPS proxy.
/// @dev Inherit and call _deployERC721Factory() inside your broadcast.
contract DeployERC721Factory is DeployBase {
    struct ERC721FactoryResult {
        address factory;
        address factoryImpl;
        address factoryBeacon;
        address peggedImpl;
    }

    function _deployERC721Factory(address initialOwner) internal returns (ERC721FactoryResult memory r) {
        r.peggedImpl = address(new ERC721PeggedToken());
        r.factory = Upgrades.deployUUPSProxy(
            "ERC721TokenFactory.sol:ERC721TokenFactory",
            abi.encodeCall(ERC721TokenFactory.initialize, (initialOwner, r.peggedImpl))
        );
        r.factoryImpl = Upgrades.getImplementationAddress(r.factory);
        r.factoryBeacon = ERC721TokenFactory(r.factory).beacon();
    }

    /// @dev Standalone: INITIAL_OWNER required.
    function run() external virtual {
        address initialOwner = vm.envAddress("INITIAL_OWNER");
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying ERC721TokenFactory");
        console2.log("  initialOwner:", initialOwner);

        vm.startBroadcast();
        ERC721FactoryResult memory r = _deployERC721Factory(initialOwner);
        vm.stopBroadcast();

        console2.log("ERC721TokenFactory deployed:", r.factory);
        console2.log("  impl:", r.factoryImpl);
        console2.log("  beacon:", r.factoryBeacon);
        console2.log("  peggedImpl:", r.peggedImpl);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "erc721_factory", r.factory);
            out = vm.serializeAddress("deployment", "erc721_factory_impl", r.factoryImpl);
            out = vm.serializeAddress("deployment", "erc721_factory_beacon", r.factoryBeacon);
            out = vm.serializeAddress("deployment", "erc721_pegged_impl", r.peggedImpl);
            vm.writeJson(out, outputPath);
        }
    }
}
