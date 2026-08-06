// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

import {DeployBase} from "./DeployBase.s.sol";
import {DeployERC721Factory} from "./DeployERC721Factory.s.sol";
import {DeployERC721Gateway} from "./DeployERC721Gateway.s.sol";
import {DeployERC1155Factory} from "./DeployERC1155Factory.s.sol";
import {DeployERC1155Gateway} from "./DeployERC1155Gateway.s.sol";

/**
 * @notice Deploys NFT bridge factories and gateways for one chain.
 * @dev Run once per chain after the bridge is deployed. Performs *only* CREATEs — exactly 10, in a
 *      fixed order — so the gateway addresses come out identical on both chains when the deployer
 *      starts from the same nonce. Wiring lives in SetupNFT, which keeps the sequence identical
 *      across chains and lets a multisig own the contracts from block zero.
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

    /// @dev pegged impl + factory (impl, proxy) + gateway (impl, proxy), twice. Beacons are created
    ///      by the factory inside `initialize` and consume no deployer nonce.
    uint256 private constant NONCE_MAP_SIZE = 10;

    function run() external override(DeployERC721Factory, DeployERC721Gateway, DeployERC1155Factory, DeployERC1155Gateway) {
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

        address[NONCE_MAP_SIZE] memory predicted = _predictAddresses(msg.sender);

        vm.startBroadcast();
        ERC721FactoryResult memory erc721Factory = _deployERC721Factory(initialOwner);
        ERC721GatewayResult memory erc721Gateway = _deployERC721Gateway(initialOwner, bridge, erc721Factory.factory);

        ERC1155FactoryResult memory erc1155Factory = _deployERC1155Factory(initialOwner);
        ERC1155GatewayResult memory erc1155Gateway = _deployERC1155Gateway(initialOwner, bridge, erc1155Factory.factory);
        vm.stopBroadcast();

        _assertPredicted(predicted, erc721Factory, erc721Gateway, erc1155Factory, erc1155Gateway);
        _writeManifest(outputPath, erc721Factory, erc721Gateway, erc1155Factory, erc1155Gateway);

        console2.log("ERC721 factory:", erc721Factory.factory);
        console2.log("ERC721 gateway:", erc721Gateway.gateway);
        console2.log("ERC1155 factory:", erc1155Factory.factory);
        console2.log("ERC1155 gateway:", erc1155Gateway.gateway);
        console2.log("");
        console2.log("Next: SetupNFT (setPaymentGateway / setOtherSide / registerGateway) once both chains are deployed.");
    }

    /// @dev The addresses this run will produce. Identical on both chains when the start nonce is,
    ///      which is the whole mechanism behind parity — worth seeing before anything is sent.
    function _predictAddresses(address deployer) internal view returns (address[NONCE_MAP_SIZE] memory predicted) {
        uint256 startNonce = vm.getNonce(deployer);

        for (uint256 i = 0; i < NONCE_MAP_SIZE; i++) {
            predicted[i] = vm.computeCreateAddress(deployer, startNonce + i);
        }

        console2.log("");
        console2.log("Predicted CREATE addresses (deployer, start nonce):", deployer, startNonce);
        string[NONCE_MAP_SIZE] memory labels = _nonceMapLabels();
        for (uint256 i = 0; i < NONCE_MAP_SIZE; i++) {
            console2.log(string.concat("  nonce ", vm.toString(startNonce + i), "  ", labels[i]), predicted[i]);
        }
        console2.log("");
    }

    /// @dev A mismatch means the CREATE order changed (dependency bump, script edit) and the other
    ///      chain would land elsewhere — fail here rather than after deploying the second side.
    function _assertPredicted(
        address[NONCE_MAP_SIZE] memory predicted,
        ERC721FactoryResult memory erc721Factory,
        ERC721GatewayResult memory erc721Gateway,
        ERC1155FactoryResult memory erc1155Factory,
        ERC1155GatewayResult memory erc1155Gateway
    ) internal pure {
        address[NONCE_MAP_SIZE] memory actual = [
            erc721Factory.peggedImpl,
            erc721Factory.factoryImpl,
            erc721Factory.factory,
            erc721Gateway.gatewayImpl,
            erc721Gateway.gateway,
            erc1155Factory.peggedImpl,
            erc1155Factory.factoryImpl,
            erc1155Factory.factory,
            erc1155Gateway.gatewayImpl,
            erc1155Gateway.gateway
        ];
        string[NONCE_MAP_SIZE] memory labels = _nonceMapLabels();

        for (uint256 i = 0; i < NONCE_MAP_SIZE; i++) {
            require(actual[i] == predicted[i], string.concat("nonce map drift: ", labels[i]));
        }
    }

    function _nonceMapLabels() internal pure returns (string[NONCE_MAP_SIZE] memory labels) {
        labels[0] = "erc721 pegged impl";
        labels[1] = "erc721 factory impl";
        labels[2] = "erc721 factory proxy";
        labels[3] = "erc721 gateway impl";
        labels[4] = "erc721 gateway proxy";
        labels[5] = "erc1155 pegged impl";
        labels[6] = "erc1155 factory impl";
        labels[7] = "erc1155 factory proxy";
        labels[8] = "erc1155 gateway impl";
        labels[9] = "erc1155 gateway proxy";
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
