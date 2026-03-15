// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, stdJson, console2} from "forge-std/Script.sol";

/**
 * @notice Link two deployed bridge/gateway stacks (source <-> destination).
 * @dev Solidity equivalent of scripts/deploy/bash/setup.bash and setup-chain.sh.
 *
 * Environment:
 * - SOURCE_CHAIN (optional, default: "sepolia")
 * - DEST_CHAIN   (optional, default: "fluent_testnet")
 * - SOURCE_JSON  (optional, default: "deployments/<SOURCE_CHAIN>.json")
 * - DEST_JSON    (optional, default: "deployments/<DEST_CHAIN>.json")
 *
 * Source JSON fields:
 * - .rpcUrl
 * - .deployment.bridge
 * - .deployment.factory
 * - .deployment.gateway
 * - .deployment.factory_beacon
 * - .deployment.pegged_impl
 *
 * Destination JSON fields:
 * - .rpcUrl
 * - .chainId
 * - .deployment.bridge
 * - .deployment.factory
 * - .deployment.gateway
 * - .deployment.factory_beacon
 * - .deployment.pegged_impl
 */
contract SetupBridge is Script {
    using stdJson for string;

    address internal constant ZERO = address(0);
    address internal constant UNIVERSAL_RUNTIME = 0x0000000000000000000000000000000000520008;

    struct ChainConfig {
        string rpcUrl;
        uint256 chainId;
        address bridge;
        address factory;
        address gateway;
        address factoryBeacon;
        address peggedImpl;
    }

    function run() external {
        string memory sourceChain = vm.envOr("SOURCE_CHAIN", string("sepolia"));
        string memory destChain = vm.envOr("DEST_CHAIN", string("fluent_testnet"));

        string memory sourceJsonPath = vm.envOr("SOURCE_JSON", string.concat("deployments/", sourceChain, ".json"));
        string memory destJsonPath = vm.envOr("DEST_JSON", string.concat("deployments/", destChain, ".json"));

        ChainConfig memory src = _loadChainConfig(sourceJsonPath, sourceChain, true);
        ChainConfig memory dst = _loadChainConfig(destJsonPath, destChain, false);

        _validateSource(src);
        _validateDestination(dst);

        console2.log("=== Setup: source -> destination ===");
        console2.log("source bridge", src.bridge);
        console2.log("destination bridge", dst.bridge);

        string memory privateKey = vm.envString("PRIVATE_KEY");
        require(bytes(privateKey).length != 0, "PRIVATE_KEY missing");

        // Link bridge <-> bridge (cross-chain via cast send)
        _castSend(src.rpcUrl, privateKey, src.bridge, "setOtherBridge(address)", vm.toString(dst.bridge));
        _castSend(dst.rpcUrl, privateKey, dst.bridge, "setOtherBridge(address)", vm.toString(src.bridge));

        // Configure source gateway for destination side
        if (dst.factoryBeacon == ZERO) {
            // Universal destination (Fluent): use universal runtime as token impl.
            _castSend(
                src.rpcUrl,
                privateKey,
                src.gateway,
                "setOtherSideUniversal(address,address,address,uint256)",
                vm.toString(dst.gateway),
                vm.toString(_nonZero(dst.peggedImpl, UNIVERSAL_RUNTIME)),
                vm.toString(dst.factory),
                vm.toString(dst.chainId)
            );
        } else {
            _castSend(
                src.rpcUrl,
                privateKey,
                src.gateway,
                "setOtherSide(address,address,address,address)",
                vm.toString(dst.gateway),
                vm.toString(dst.peggedImpl),
                vm.toString(dst.factory),
                vm.toString(dst.factoryBeacon)
            );
        }

        // Configure destination gateway for source side
        _castSend(
            dst.rpcUrl,
            privateKey,
            dst.gateway,
            "setOtherSide(address,address,address,address)",
            vm.toString(src.gateway),
            vm.toString(src.peggedImpl),
            vm.toString(src.factory),
            vm.toString(src.factoryBeacon)
        );

        console2.log("Bridges and gateways linked successfully.");
    }

    function _loadChainConfig(string memory jsonPath, string memory chainName, bool sourceSide) internal view returns (ChainConfig memory c) {
        string memory json = vm.readFile(jsonPath);
        c.rpcUrl = _readRpcUrl(json, chainName);
        c.chainId = sourceSide ? 0 : _readChainId(json, chainName);
        c.bridge = _readAddressFlexible(json, "bridge");
        c.factory = _readAddressFlexible(json, "factory");
        c.gateway = _readAddressFlexible(json, "gateway");
        c.factoryBeacon = _readAddressFlexible(json, "factory_beacon");
        c.peggedImpl = _readAddressFlexible(json, "pegged_impl");
    }

    function _validateSource(ChainConfig memory c) internal pure {
        require(bytes(c.rpcUrl).length != 0, "source rpcUrl missing");
        require(c.bridge != ZERO, "source bridge missing");
        require(c.factory != ZERO, "source factory missing");
        require(c.gateway != ZERO, "source gateway missing");
        require(c.factoryBeacon != ZERO, "source factory_beacon missing");
        require(c.peggedImpl != ZERO, "source pegged_impl missing");
    }

    function _validateDestination(ChainConfig memory c) internal pure {
        require(bytes(c.rpcUrl).length != 0, "destination rpcUrl missing");
        require(c.chainId != 0, "destination chainId missing");
        require(c.bridge != ZERO, "destination bridge missing");
        require(c.factory != ZERO, "destination factory missing");
        require(c.gateway != ZERO, "destination gateway missing");
        // destination may be universal, where beacon is zero.
        if (c.factoryBeacon != ZERO) {
            require(c.peggedImpl != ZERO, "destination pegged_impl missing");
        }
    }

    function _nonZero(address value, address fallbackValue) internal pure returns (address) {
        if (value == ZERO) return fallbackValue;
        return value;
    }

    function _readAddressFlexible(string memory json, string memory key) internal view returns (address) {
        string memory nestedPath = string.concat(".deployment.", key);
        if (vm.keyExistsJson(json, nestedPath)) return json.readAddress(nestedPath);
        string memory flatPath = string.concat(".", key);
        if (vm.keyExistsJson(json, flatPath)) return json.readAddress(flatPath);
        return ZERO;
    }

    function _readRpcUrl(string memory json, string memory chainName) internal view returns (string memory) {
        if (vm.keyExistsJson(json, ".rpcUrl")) {
            string memory rpc = json.readString(".rpcUrl");
            if (bytes(rpc).length != 0) return rpc;
        }

        bytes32 c = keccak256(bytes(chainName));
        if (c == keccak256(bytes("sepolia"))) return vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (c == keccak256(bytes("fluent_dev"))) return vm.envOr("FLUENT_DEV_RPC_URL", string(""));
        if (c == keccak256(bytes("fluent_testnet"))) return vm.envOr("FLUENT_TESTNET_RPC_URL", string(""));
        return vm.envOr("RPC_URL", string(""));
    }

    function _readChainId(string memory json, string memory chainName) internal view returns (uint256) {
        if (vm.keyExistsJson(json, ".chainId")) {
            uint256 id = json.readUint(".chainId");
            if (id != 0) return id;
        }

        bytes32 c = keccak256(bytes(chainName));
        if (c == keccak256(bytes("sepolia"))) return 11155111;
        if (c == keccak256(bytes("fluent_dev"))) return 20993;
        if (c == keccak256(bytes("fluent_testnet"))) return 20994;
        return 0;
    }

    function _castSend(string memory rpc, string memory pk, address to, string memory sig, string memory arg1) internal {
        string[] memory cmd = new string[](10);
        cmd[0] = "cast";
        cmd[1] = "send";
        cmd[2] = vm.toString(to);
        cmd[3] = sig;
        cmd[4] = arg1;
        cmd[5] = "--rpc-url";
        cmd[6] = rpc;
        cmd[7] = "--private-key";
        cmd[8] = pk;
        cmd[9] = "--legacy";
        vm.ffi(cmd);
    }

    function _castSend(
        string memory rpc,
        string memory pk,
        address to,
        string memory sig,
        string memory arg1,
        string memory arg2,
        string memory arg3,
        string memory arg4
    ) internal {
        string[] memory cmd = new string[](13);
        cmd[0] = "cast";
        cmd[1] = "send";
        cmd[2] = vm.toString(to);
        cmd[3] = sig;
        cmd[4] = arg1;
        cmd[5] = arg2;
        cmd[6] = arg3;
        cmd[7] = arg4;
        cmd[8] = "--rpc-url";
        cmd[9] = rpc;
        cmd[10] = "--private-key";
        cmd[11] = pk;
        cmd[12] = "--legacy";
        vm.ffi(cmd);
    }
}
