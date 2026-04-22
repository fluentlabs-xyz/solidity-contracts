// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {DeployBase} from "../deploy/DeployBase.s.sol";
import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {WETHGateway} from "../../contracts/gateways/WETHGateway.sol";
import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";

/// @title RunReleaseWethL1
/// @notice One-command L1 flow: deploy WETH gateway, upgrade L1 ERC20 gateway, wire L1 side.
///
/// @dev Required env vars:
///      - ENV_SUFFIX: "testnet" or "mainnet"
///      - DEPLOYER: deployer EOA address
///      - UPGRADER: signer that owns upgradeable proxies
///      - WIRER: gateway owner + bridge admin address
///
/// @dev Optional env vars:
///      - TARGET_NONCE: nonce target override (defaults: testnet=41, mainnet=19)
///
/// @dev Example:
///      forge script scripts/migrations/RunReleaseWethL1.s.sol:RunReleaseWethL1 \
///        --rpc-url "$L1_RPC" --sender "$DEPLOYER" --broadcast --unlocked
contract RunReleaseWethL1 is DeployBase {
    struct Context {
        string env;
        address deployer;
        address upgrader;
        address wirer;
        uint256 targetNonce;
        address bridge;
        address erc20;
        address gatewayOwner;
        address l1Weth;
        address excluded;
    }

    function run() external {
        Context memory c;
        c.env = _requireEnvSuffix();
        string memory cfg = vm.readFile(_releaseConfigPath(c.env));
        string memory l1Manifest = vm.readFile(_manifestPath(c.env, true));

        c.deployer = vm.envAddress("DEPLOYER");
        c.upgrader = _optionalSigner("UPGRADER", c.deployer);
        c.wirer = vm.envAddress("WIRER");
        c.targetNonce = _targetNonceForEnv(c.env);

        c.bridge = _readAddr(l1Manifest, "bridge");
        c.erc20 = _readAddr(l1Manifest, "erc20_gateway");
        c.gatewayOwner = _readAddr(cfg, "gateway_initial_owner");
        c.l1Weth = _readAddr(cfg, "l1_weth");
        c.excluded = _readAddr(cfg, "bridging_exclude_l1_weth");
        if (c.excluded == address(0)) c.excluded = c.l1Weth;

        require(c.bridge != address(0) && c.bridge.code.length > 0, "l1 bridge missing");
        require(c.erc20 != address(0) && c.erc20.code.length > 0, "l1 erc20 gateway missing");
        require(c.gatewayOwner != address(0), "gateway_initial_owner missing");
        require(c.l1Weth != address(0) && c.l1Weth.code.length > 0, "l1_weth missing");
        require(c.excluded != address(0), "bridging_exclude_l1_weth missing");

        vm.startBroadcast(c.deployer);
        _bumpNonceTo(c.targetNonce, c.deployer);
        (address impl, address proxy) = _deployGateway(c.bridge, c.gatewayOwner);
        vm.stopBroadcast();

        vm.startBroadcast(c.upgrader);
        _upgradeL1ERC20Gateway(c.erc20, c.excluded);
        vm.stopBroadcast();

        vm.startBroadcast(c.wirer);
        WETHGateway(payable(proxy)).setWETH(c.l1Weth);
        WETHGateway(payable(proxy)).setOtherSideGateway(proxy);
        L1FluentBridge(payable(c.bridge)).registerGateway(proxy);
        vm.stopBroadcast();

        console2.log("L1 flow complete for env:", c.env);
        console2.log("  deployer      :", c.deployer);
        console2.log("  upgrader      :", c.upgrader);
        console2.log("  wirer         :", c.wirer);
        console2.log("  target nonce  :", c.targetNonce);
        console2.log("  gateway impl  :", impl);
        console2.log("  gateway proxy :", proxy);
    }

    function _upgradeL1ERC20Gateway(address erc20, address excluded) internal {
        address newImpl = address(new ERC20Gateway());
        UnsafeUpgrades.upgradeProxy(payable(erc20), newImpl, "");
        ERC20Gateway(payable(erc20)).setBridgingExcludedOrigin(excluded, true);
    }

    function _deployGateway(address bridge, address owner) internal returns (address impl, address proxy) {
        impl = address(new WETHGateway());
        bytes memory initData = abi.encodeCall(WETHGateway.initialize, (owner, bridge, address(0)));
        proxy = address(new ERC1967Proxy(impl, initData));
    }

    function _bumpNonceTo(uint256 target, address deployer) internal {
        uint256 cur = vm.getNonce(deployer);
        require(cur <= target, "deployer nonce above target");
        while (cur < target) {
            (bool ok, ) = payable(deployer).call{value: 0}("");
            require(ok, "nonce-burn self-send failed");
            unchecked {
                cur++;
            }
        }
    }

    function _manifestPath(string memory env, bool isL1) internal pure returns (string memory) {
        return string.concat("deployments/", env, isL1 ? "/l1.json" : "/l2.json");
    }

    function _releaseConfigPath(string memory env) internal pure returns (string memory) {
        return string.concat("scripts/config/", env, "/release_weth.json");
    }

    function _optionalSigner(string memory name, address fallbackSigner) internal view returns (address) {
        if (vm.envExists(name)) return vm.envAddress(name);
        return fallbackSigner;
    }

    function _targetNonceForEnv(string memory env) internal view returns (uint256) {
        if (vm.envExists("TARGET_NONCE")) {
            return vm.envUint("TARGET_NONCE");
        }
        bytes32 envHash = keccak256(bytes(env));
        if (envHash == keccak256("testnet")) return 41;
        if (envHash == keccak256("mainnet")) return 19;
        revert("unsupported ENV_SUFFIX");
    }

    function _requireEnvSuffix() internal view returns (string memory env) {
        env = vm.envString("ENV_SUFFIX");
        bytes32 envHash = keccak256(bytes(env));
        require(envHash == keccak256("testnet") || envHash == keccak256("mainnet"), "ENV_SUFFIX must be testnet/mainnet");
    }
}
