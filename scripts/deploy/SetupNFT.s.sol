// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson, console2} from "forge-std/Script.sol";

import {ERC721Gateway} from "../../contracts/gateways/ERC721Gateway.sol";
import {ERC1155Gateway} from "../../contracts/gateways/ERC1155Gateway.sol";
import {GenericTokenFactory} from "../../contracts/factories/GenericTokenFactory.sol";
import {DeployBase} from "./DeployBase.s.sol";

interface INFTBridgeAdmin {
    function setExecuteGasLimit(uint256 newExecuteGasLimit) external;
    function registerGateway(address gateway) external;
    function isGatewayRegistered(address gateway) external view returns (bool);
}

interface IGatewayBlacklistAdmin {
    function setBlacklistRegistry(address newBlacklistRegistry) external;
    function getBlacklistRegistry() external view returns (address);
}

/**
 * @notice Wires the local NFT gateways against the remote chain deployment.
 * @dev Run per chain, after DeployNFT has completed on **both** sides — `setOtherSide` needs the
 *      remote manifest. Either broadcasts the calls from the running key (testnet, where it owns
 *      everything) or writes a Safe Transaction Builder JSON (mainnet, where the Safe does).
 *
 * Environment:
 * - ENV / LOCAL_NETWORK / REMOTE_NETWORK (default: testnet / l1 / l2) select the manifests and
 *   configs under deployments/<ENV>/ and scripts/config/<ENV>/. Individual paths can be overridden
 *   with SOURCE_JSON, SOURCE_NFT_JSON, DEST_NFT_JSON, SOURCE_CONFIG, DEST_CONFIG.
 * - SAFE_BATCH (default: false) writes the JSON instead of broadcasting; SAFE_ADDRESS (default:
 *   config roles.initialOwner) and SAFE_BATCH_PATH control its metadata and location.
 * - BLACKLIST_REGISTRY (default: `blacklist_proxy` in the local manifest) is wired into both
 *   gateways; zero opts out. Chains without a registry simply lack the key.
 * - SET_EXECUTE_GAS_LIMIT (default: false) + EXECUTE_GAS_LIMIT opt into changing the bridge-wide
 *   execute gas limit. Off by default: the value applies to every gateway, not just NFT.
 *
 * Both modes need `--rpc-url` on the local chain — the registration and chain-id checks are reads.
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

    /// @dev `label` is human-facing only: console output and the batch description.
    struct Call {
        address to;
        bytes data;
        string label;
    }

    /// @dev Optional parts of the batch. A struct rather than positional parameters because these
    ///      are same-typed pairs, and a swapped argument would be signed as valid calldata.
    ///      Zero/false omits the corresponding call.
    struct WiringOptions {
        uint256 remoteChainId;
        bool register721;
        bool register1155;
        address blacklist721;
        address blacklist1155;
        uint256 executeGasLimit;
    }

    /// @dev 2 setPaymentGateway + 2 setOtherSide + 2 setBlacklistRegistry + 2 registerGateway
    ///      + 1 setExecuteGasLimit.
    uint256 private constant MAX_CALLS = 9;

    function run() external {
        string memory env = vm.envOr("ENV", string("testnet"));
        string memory localNetwork = vm.envOr("LOCAL_NETWORK", string("l1"));
        string memory remoteNetwork = vm.envOr("REMOTE_NETWORK", string("l2"));

        string memory sourceJson = vm.readFile(vm.envOr("SOURCE_JSON", string.concat("deployments/", env, "/", localNetwork, ".json")));
        string memory localNftJson = vm.readFile(
            vm.envOr("SOURCE_NFT_JSON", string.concat("deployments/", env, "/", localNetwork, ".nft.json"))
        );
        string memory remoteNftJson = vm.readFile(
            vm.envOr("DEST_NFT_JSON", string.concat("deployments/", env, "/", remoteNetwork, ".nft.json"))
        );
        string memory sourceConfig = vm.readFile(vm.envOr("SOURCE_CONFIG", string.concat("scripts/config/", env, "/", localNetwork, ".json")));
        string memory destConfig = vm.readFile(vm.envOr("DEST_CONFIG", string.concat("scripts/config/", env, "/", remoteNetwork, ".json")));

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
        _requireLocalChainId(sourceConfig);

        address blacklist = _resolveBlacklistRegistry(sourceJson);
        Call[] memory calls = buildCalls(
            bridge,
            local,
            remote,
            WiringOptions({
                remoteChainId: remoteChainId,
                register721: !INFTBridgeAdmin(bridge).isGatewayRegistered(local.erc721Gateway),
                register1155: !INFTBridgeAdmin(bridge).isGatewayRegistered(local.erc1155Gateway),
                blacklist721: _blacklistCallTarget(local.erc721Gateway, blacklist),
                blacklist1155: _blacklistCallTarget(local.erc1155Gateway, blacklist),
                executeGasLimit: _resolveExecuteGasLimit(sourceConfig)
            })
        );

        console2.log("Configuring NFT gateways");
        console2.log("  bridge:", bridge);
        console2.log("  remoteChainId:", remoteChainId);
        console2.log("  erc721 gateway:", local.erc721Gateway);
        console2.log("  erc1155 gateway:", local.erc1155Gateway);
        console2.log("  calls:", calls.length);

        if (vm.envOr("SAFE_BATCH", false)) {
            _writeSafeBatch(env, localNetwork, sourceConfig, calls);
        } else {
            _broadcast(calls);
        }
    }

    /// @notice Builds the wiring sequence. Pure, so the exact calldata can be asserted on directly.
    function buildCalls(
        address bridge,
        NftManifest memory local,
        NftManifest memory remote,
        WiringOptions memory opts
    ) public pure returns (Call[] memory calls) {
        Call[MAX_CALLS] memory buf;
        uint256 n;

        // Without this the factory refuses `deployToken` from the gateway.
        buf[n++] = Call({
            to: local.erc721Factory,
            data: abi.encodeCall(GenericTokenFactory.setPaymentGateway, (local.erc721Gateway)),
            label: "erc721Factory.setPaymentGateway"
        });
        buf[n++] = Call({
            to: local.erc1155Factory,
            data: abi.encodeCall(GenericTokenFactory.setPaymentGateway, (local.erc1155Gateway)),
            label: "erc1155Factory.setPaymentGateway"
        });

        // Remote coordinates: the gateway to accept messages from, and the factory/beacon the
        // pegged-token address on the other side is derived from.
        buf[n++] = Call({
            to: local.erc721Gateway,
            data: abi.encodeCall(
                ERC721Gateway.setOtherSide,
                (remote.erc721Gateway, opts.remoteChainId, remote.erc721PeggedImpl, remote.erc721Factory, remote.erc721Beacon)
            ),
            label: "erc721Gateway.setOtherSide"
        });
        buf[n++] = Call({
            to: local.erc1155Gateway,
            data: abi.encodeCall(
                ERC1155Gateway.setOtherSide,
                (remote.erc1155Gateway, opts.remoteChainId, remote.erc1155PeggedImpl, remote.erc1155Factory, remote.erc1155Beacon)
            ),
            label: "erc1155Gateway.setOtherSide"
        });

        // Deposit screening. Before bridge admission, so the gateway is never reachable unfiltered.
        if (opts.blacklist721 != address(0)) {
            buf[n++] = Call({
                to: local.erc721Gateway,
                data: abi.encodeCall(IGatewayBlacklistAdmin.setBlacklistRegistry, (opts.blacklist721)),
                label: "erc721Gateway.setBlacklistRegistry"
            });
        }
        if (opts.blacklist1155 != address(0)) {
            buf[n++] = Call({
                to: local.erc1155Gateway,
                data: abi.encodeCall(IGatewayBlacklistAdmin.setBlacklistRegistry, (opts.blacklist1155)),
                label: "erc1155Gateway.setBlacklistRegistry"
            });
        }

        // Bridge admission. Gates both send and receive; one entry covers both because the gateway
        // addresses match across chains.
        if (opts.register721) {
            buf[n++] = Call({
                to: bridge,
                data: abi.encodeCall(INFTBridgeAdmin.registerGateway, (local.erc721Gateway)),
                label: "bridge.registerGateway(erc721)"
            });
        }
        if (opts.register1155) {
            buf[n++] = Call({
                to: bridge,
                data: abi.encodeCall(INFTBridgeAdmin.registerGateway, (local.erc1155Gateway)),
                label: "bridge.registerGateway(erc1155)"
            });
        }

        if (opts.executeGasLimit != 0) {
            buf[n++] = Call({
                to: bridge,
                data: abi.encodeCall(INFTBridgeAdmin.setExecuteGasLimit, (opts.executeGasLimit)),
                label: "bridge.setExecuteGasLimit"
            });
        }

        calls = new Call[](n);
        for (uint256 i = 0; i < n; i++) {
            calls[i] = buf[i];
        }
    }

    /// @dev Executes the sequence from the broadcasting key. Testnet/local path.
    function _broadcast(Call[] memory calls) internal {
        vm.startBroadcast();
        for (uint256 i = 0; i < calls.length; i++) {
            console2.log("  ->", calls[i].label);
            (bool ok, bytes memory ret) = calls[i].to.call(calls[i].data);
            if (!ok) {
                console2.log("  FAILED:", calls[i].label);
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        vm.stopBroadcast();
    }

    /**
     * @dev Writes a Safe Transaction Builder JSON with raw calldata (`contractMethod: null`), so the
     *      UI cannot re-encode an argument. `chainId` comes from the connected chain — the import is
     *      rejected on mismatch, which is what stops the L1 batch reaching the L2 Safe.
     */
    function _writeSafeBatch(string memory env, string memory localNetwork, string memory sourceConfig, Call[] memory calls) internal {
        address safe = vm.envOr("SAFE_ADDRESS", sourceConfig.readAddress(".roles.initialOwner"));
        require(safe != address(0), "SAFE_ADDRESS required");

        string memory path = vm.envOr("SAFE_BATCH_PATH", string.concat("deployments/", env, "/safe-batch-", localNetwork, ".json"));

        string memory description;
        for (uint256 i = 0; i < calls.length; i++) {
            description = i == 0 ? calls[i].label : string.concat(description, ", ", calls[i].label);
        }

        string memory json = string.concat(
            "{\n",
            '  "version": "1.0",\n',
            '  "chainId": "',
            vm.toString(block.chainid),
            '",\n',
            '  "createdAt": 0,\n',
            '  "meta": {\n',
            '    "name": "NFT gateway wiring - ',
            env,
            " ",
            localNetwork,
            '",\n',
            '    "description": "',
            description,
            '",\n',
            '    "createdFromSafeAddress": "',
            vm.toString(safe),
            '"\n',
            "  },\n",
            '  "transactions": [\n'
        );

        for (uint256 i = 0; i < calls.length; i++) {
            json = string.concat(
                json,
                "    {\n",
                '      "to": "',
                vm.toString(calls[i].to),
                '",\n',
                '      "value": "0",\n',
                '      "data": "',
                vm.toString(calls[i].data),
                '",\n',
                '      "contractMethod": null,\n',
                '      "contractInputsValues": null\n',
                i + 1 == calls.length ? "    }\n" : "    },\n"
            );
        }

        json = string.concat(json, "  ]\n}\n");
        vm.writeFile(path, json);

        console2.log("");
        console2.log("Safe batch written:", path);
        console2.log("  safe:", safe);
        console2.log("  chainId:", block.chainid);
        for (uint256 i = 0; i < calls.length; i++) {
            console2.log(string.concat("  ", vm.toString(i + 1), ". ", calls[i].label), calls[i].to);
        }
        console2.log("");
        console2.log("Import it in the Safe UI -> Transaction Builder. It executes as one batched transaction.");
    }

    /// @dev Zero unless opted into: the limit is bridge-wide, and a stale config value would
    ///      silently rewrite a live setting while wiring NFTs.
    function _resolveExecuteGasLimit(string memory sourceConfig) internal view returns (uint256) {
        if (!vm.envOr("SET_EXECUTE_GAS_LIMIT", false)) return 0;

        uint256 fromConfig = vm.keyExistsJson(sourceConfig, ".bridge.executeGasLimit") ? sourceConfig.readUint(".bridge.executeGasLimit") : 0;
        uint256 limit = vm.envOr("EXECUTE_GAS_LIMIT", fromConfig);
        require(limit != 0, "EXECUTE_GAS_LIMIT required when SET_EXECUTE_GAS_LIMIT=true");
        return limit;
    }

    /// @dev Registry for this chain, from the local manifest unless overridden. Chains without one
    ///      have no such key, and the calls drop out of the batch.
    function _resolveBlacklistRegistry(string memory sourceJson) internal view returns (address) {
        return vm.envOr("BLACKLIST_REGISTRY", _readAddr(sourceJson, "blacklist_proxy"));
    }

    /// @dev Zero when there is nothing to do: no registry, or the gateway already points at it.
    function _blacklistCallTarget(address gateway, address registry) internal view returns (address) {
        if (registry == address(0)) return address(0);
        if (IGatewayBlacklistAdmin(gateway).getBlacklistRegistry() == registry) return address(0);
        return registry;
    }

    /// @dev Guards against running with the wrong `--rpc-url` / `LOCAL_NETWORK` pair.
    function _requireLocalChainId(string memory sourceConfig) internal view {
        if (!vm.keyExistsJson(sourceConfig, ".chainId")) return;
        require(sourceConfig.readUint(".chainId") == block.chainid, "local chain ID mismatch (wrong --rpc-url?)");
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
}
