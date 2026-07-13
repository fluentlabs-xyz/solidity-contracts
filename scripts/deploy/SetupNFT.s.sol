// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson, console2} from "forge-std/Script.sol";

import {ERC721Gateway} from "../../contracts/gateways/ERC721Gateway.sol";
import {ERC1155Gateway} from "../../contracts/gateways/ERC1155Gateway.sol";
import {DeployBase} from "./DeployBase.s.sol";

interface INFTBridgeAdmin {
    function setExecuteGasLimit(uint256 newExecuteGasLimit) external;
    function registerGateway(address gateway) external;
    function isGatewayRegistered(address gateway) external view returns (bool);
}

/**
 * @notice Configures local NFT gateways against the remote chain deployment.
 * @dev Run once per chain after DeployNFT has completed on both sides.
 *      Gateway/factory setters require owner. Bridge registerGateway/setExecuteGasLimit require DEFAULT_ADMIN_ROLE.
 *
 * Environment:
 * - ENV (optional, default: "testnet") selects deployments/<ENV> and scripts/config/<ENV>.
 * - LOCAL_NETWORK (optional, default: "l1") selects local manifest/config suffix.
 * - REMOTE_NETWORK (optional, default: "l2") selects remote manifest/config suffix.
 * - SOURCE_JSON (optional, default: "deployments/<ENV>/<LOCAL_NETWORK>.json") has bridge address.
 * - SOURCE_NFT_JSON (optional, default: "deployments/<ENV>/<LOCAL_NETWORK>.nft.json") has local NFT addresses.
 * - DEST_NFT_JSON (optional, default: "deployments/<ENV>/<REMOTE_NETWORK>.nft.json") has remote NFT addresses.
 * - DEST_CONFIG (optional, default: "scripts/config/<ENV>/<REMOTE_NETWORK>.json") has remote chainId.
 * - SOURCE_CONFIG (optional, default: "scripts/config/<ENV>/<LOCAL_NETWORK>.json") may set bridge.executeGasLimit.
 */
contract SetupNFT is DeployBase {
    using stdJson for string;

    struct NftManifest {
        address erc721Gateway;
        address erc721Factory;
        address erc721Beacon;
        address erc721PeggedImpl;
        address erc1155Gateway;
        address erc1155Factory;
        address erc1155Beacon;
        address erc1155PeggedImpl;
    }

    function run() external {
        string memory env = vm.envOr("ENV", string("testnet"));
        string memory localNetwork = vm.envOr("LOCAL_NETWORK", string("l1"));
        string memory remoteNetwork = vm.envOr("REMOTE_NETWORK", string("l2"));

        string memory sourceJson =
            vm.readFile(vm.envOr("SOURCE_JSON", string.concat("deployments/", env, "/", localNetwork, ".json")));
        string memory localNftJson = vm.readFile(
            vm.envOr("SOURCE_NFT_JSON", string.concat("deployments/", env, "/", localNetwork, ".nft.json"))
        );
        string memory remoteNftJson =
            vm.readFile(vm.envOr("DEST_NFT_JSON", string.concat("deployments/", env, "/", remoteNetwork, ".nft.json")));
        string memory sourceConfig =
            vm.readFile(vm.envOr("SOURCE_CONFIG", string.concat("scripts/config/", env, "/", localNetwork, ".json")));
        string memory destConfig =
            vm.readFile(vm.envOr("DEST_CONFIG", string.concat("scripts/config/", env, "/", remoteNetwork, ".json")));

        address bridge = _readAddr(sourceJson, "bridge");
        NftManifest memory local = _readNftManifest(localNftJson);
        NftManifest memory remote = _readNftManifest(remoteNftJson);
        uint256 remoteChainId = destConfig.readUint(".chainId");

        require(bridge != address(0), "bridge address missing");
        require(remoteChainId != 0, "remote chain ID missing");
        _requireManifest(local, "local");
        _requireManifest(remote, "remote");
        require(local.erc721Gateway == remote.erc721Gateway, "ERC721 gateway address mismatch");
        require(local.erc1155Gateway == remote.erc1155Gateway, "ERC1155 gateway address mismatch");

        console2.log("Configuring NFT gateways");
        console2.log("  bridge:", bridge);
        console2.log("  remoteChainId:", remoteChainId);
        console2.log("  erc721 gateway:", local.erc721Gateway);
        console2.log("  erc1155 gateway:", local.erc1155Gateway);

        vm.startBroadcast();
        ERC721Gateway(payable(local.erc721Gateway))
            .setOtherSide(
                remote.erc721Gateway, remoteChainId, remote.erc721PeggedImpl, remote.erc721Factory, remote.erc721Beacon
            );
        ERC1155Gateway(payable(local.erc1155Gateway))
            .setOtherSide(
                remote.erc1155Gateway,
                remoteChainId,
                remote.erc1155PeggedImpl,
                remote.erc1155Factory,
                remote.erc1155Beacon
            );
        _registerGatewayIfNeeded(bridge, local.erc721Gateway);
        _registerGatewayIfNeeded(bridge, local.erc1155Gateway);
        _setExecuteGasLimitIfConfigured(bridge, sourceConfig);
        vm.stopBroadcast();
    }

    function _readNftManifest(string memory json) internal view returns (NftManifest memory manifest) {
        manifest.erc721Gateway = _readAddr(json, "erc721_gateway");
        manifest.erc721Factory = _readAddr(json, "erc721_factory");
        manifest.erc721Beacon = _readAddr(json, "erc721_factory_beacon");
        manifest.erc721PeggedImpl = _readAddr(json, "erc721_pegged_impl");
        manifest.erc1155Gateway = _readAddr(json, "erc1155_gateway");
        manifest.erc1155Factory = _readAddr(json, "erc1155_factory");
        manifest.erc1155Beacon = _readAddr(json, "erc1155_factory_beacon");
        manifest.erc1155PeggedImpl = _readAddr(json, "erc1155_pegged_impl");
    }

    function _requireManifest(NftManifest memory manifest, string memory side) internal pure {
        require(manifest.erc721Gateway != address(0), string.concat(side, " ERC721 gateway missing"));
        require(manifest.erc721Factory != address(0), string.concat(side, " ERC721 factory missing"));
        require(manifest.erc721Beacon != address(0), string.concat(side, " ERC721 beacon missing"));
        require(manifest.erc721PeggedImpl != address(0), string.concat(side, " ERC721 pegged impl missing"));
        require(manifest.erc1155Gateway != address(0), string.concat(side, " ERC1155 gateway missing"));
        require(manifest.erc1155Factory != address(0), string.concat(side, " ERC1155 factory missing"));
        require(manifest.erc1155Beacon != address(0), string.concat(side, " ERC1155 beacon missing"));
        require(manifest.erc1155PeggedImpl != address(0), string.concat(side, " ERC1155 pegged impl missing"));
    }

    function _registerGatewayIfNeeded(address bridge, address gateway) internal {
        if (!INFTBridgeAdmin(bridge).isGatewayRegistered(gateway)) {
            INFTBridgeAdmin(bridge).registerGateway(gateway);
        }
    }

    function _setExecuteGasLimitIfConfigured(address bridge, string memory sourceConfig) internal {
        if (vm.keyExistsJson(sourceConfig, ".bridge.executeGasLimit")) {
            uint256 executeGasLimit = sourceConfig.readUint(".bridge.executeGasLimit");
            if (executeGasLimit > 0) {
                INFTBridgeAdmin(bridge).setExecuteGasLimit(executeGasLimit);
            }
        }
    }
}
