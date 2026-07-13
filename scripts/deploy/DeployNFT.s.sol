// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

import {ERC721TokenFactory} from "../../contracts/factories/ERC721TokenFactory.sol";
import {ERC1155TokenFactory} from "../../contracts/factories/ERC1155TokenFactory.sol";
import {DeployBase} from "./DeployBase.s.sol";
import {DeployERC721Factory} from "./DeployERC721Factory.s.sol";
import {DeployERC721Gateway} from "./DeployERC721Gateway.s.sol";
import {DeployERC1155Factory} from "./DeployERC1155Factory.s.sol";
import {DeployERC1155Gateway} from "./DeployERC1155Gateway.s.sol";

/**
 * @notice Deploys NFT bridge factories and gateways for one chain.
 * @dev Run once per chain after the bridge is deployed. The deployer nonce order must match on both chains
 *      so ERC721/1155 gateway addresses are identical across L1 and L2.
 *
 * Environment:
 * - NETWORK (optional, default: "testnet/l1") reads scripts/config/<NETWORK>.json.
 * - OUTPUT_PATH (optional, default: "deployments/<NETWORK>.nft.json") receives the NFT manifest.
 * - INITIAL_OWNER (optional, defaults to config roles.initialOwner) owns gateway/factory setters.
 * - BRIDGE_ADDRESS (optional, defaults to deployments/<NETWORK>.json bridge) is the local bridge.
 * - EXPECTED_NONCE (optional) guards the deployer nonce before broadcasting.
 */
contract DeployNFT is DeployBase, DeployERC721Factory, DeployERC721Gateway, DeployERC1155Factory, DeployERC1155Gateway {
    using stdJson for string;

    uint256 private constant NO_EXPECTED_NONCE = type(uint256).max;

    function run()
        external
        override(DeployERC721Factory, DeployERC721Gateway, DeployERC1155Factory, DeployERC1155Gateway)
    {
        string memory network = vm.envOr("NETWORK", string("testnet/l1"));
        string memory config = _readConfig(network);
        string memory outputPath = vm.envOr("OUTPUT_PATH", string.concat("deployments/", network, ".nft.json"));

        address initialOwner = vm.envOr("INITIAL_OWNER", config.readAddress(".roles.initialOwner"));
        address bridge = vm.envOr("BRIDGE_ADDRESS", _readBridgeFromManifest(network));
        uint256 expectedNonce = vm.envOr("EXPECTED_NONCE", NO_EXPECTED_NONCE);

        require(initialOwner != address(0), "INITIAL_OWNER required");
        require(bridge != address(0), "BRIDGE_ADDRESS required");
        if (expectedNonce != NO_EXPECTED_NONCE) {
            require(vm.getNonce(msg.sender) == expectedNonce, "unexpected deployer nonce");
        }

        console2.log("Deploying NFT bridge bundle");
        console2.log("  network:", network);
        console2.log("  initialOwner:", initialOwner);
        console2.log("  bridge:", bridge);
        console2.log("  outputPath:", outputPath);

        vm.startBroadcast();
        ERC721FactoryResult memory erc721Factory = _deployERC721Factory(initialOwner);
        ERC721GatewayResult memory erc721Gateway = _deployERC721Gateway(initialOwner, bridge, erc721Factory.factory);
        ERC721TokenFactory(erc721Factory.factory).setPaymentGateway(erc721Gateway.gateway);

        ERC1155FactoryResult memory erc1155Factory = _deployERC1155Factory(initialOwner);
        ERC1155GatewayResult memory erc1155Gateway = _deployERC1155Gateway(initialOwner, bridge, erc1155Factory.factory);
        ERC1155TokenFactory(erc1155Factory.factory).setPaymentGateway(erc1155Gateway.gateway);
        vm.stopBroadcast();

        _writeManifest(outputPath, erc721Factory, erc721Gateway, erc1155Factory, erc1155Gateway);

        console2.log("ERC721 factory:", erc721Factory.factory);
        console2.log("ERC721 gateway:", erc721Gateway.gateway);
        console2.log("ERC1155 factory:", erc1155Factory.factory);
        console2.log("ERC1155 gateway:", erc1155Gateway.gateway);
    }

    function _readBridgeFromManifest(string memory network) internal view returns (address) {
        string memory path = vm.envOr("DEPLOYMENT_JSON", string.concat("deployments/", network, ".json"));
        if (!vm.exists(path)) return address(0);
        return _readAddr(vm.readFile(path), "bridge");
    }

    function _writeManifest(
        string memory outputPath,
        ERC721FactoryResult memory erc721Factory,
        ERC721GatewayResult memory erc721Gateway,
        ERC1155FactoryResult memory erc1155Factory,
        ERC1155GatewayResult memory erc1155Gateway
    ) internal {
        string memory out = vm.serializeUint("deployment", "chainId", block.chainid);
        out = vm.serializeAddress("deployment", "erc721_factory", erc721Factory.factory);
        out = vm.serializeAddress("deployment", "erc721_factory_impl", erc721Factory.factoryImpl);
        out = vm.serializeAddress("deployment", "erc721_factory_beacon", erc721Factory.factoryBeacon);
        out = vm.serializeAddress("deployment", "erc721_pegged_impl", erc721Factory.peggedImpl);
        out = vm.serializeAddress("deployment", "erc721_gateway", erc721Gateway.gateway);
        out = vm.serializeAddress("deployment", "erc721_gateway_impl", erc721Gateway.gatewayImpl);
        out = vm.serializeAddress("deployment", "erc1155_factory", erc1155Factory.factory);
        out = vm.serializeAddress("deployment", "erc1155_factory_impl", erc1155Factory.factoryImpl);
        out = vm.serializeAddress("deployment", "erc1155_factory_beacon", erc1155Factory.factoryBeacon);
        out = vm.serializeAddress("deployment", "erc1155_pegged_impl", erc1155Factory.peggedImpl);
        out = vm.serializeAddress("deployment", "erc1155_gateway", erc1155Gateway.gateway);
        out = vm.serializeAddress("deployment", "erc1155_gateway_impl", erc1155Gateway.gatewayImpl);
        vm.writeJson(out, outputPath);
    }
}
