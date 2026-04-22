// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {DeployBase} from "../deploy/DeployBase.s.sol";
import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {WETHGateway} from "../../contracts/gateways/WETHGateway.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";

/// @title RunReleaseWethL2
/// @notice One-command L2 flow: deploy WETH gateway, upgrade gateways/factory, deploy Universal-WETH, wire L2 side.
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
///      forge script scripts/migrations/RunReleaseWethL2.s.sol:RunReleaseWethL2 \
///        --rpc-url "$L2_RPC" --sender "$DEPLOYER" --broadcast --unlocked --skip-simulation
contract RunReleaseWethL2 is DeployBase {
    struct Context {
        string env;
        address deployer;
        address upgrader;
        address wirer;
        uint256 targetNonce;
        address bridge;
        address erc20;
        address factory;
        address gatewayOwner;
        address l1Weth;
    }

    function run() external {
        Context memory c;
        c.env = _requireEnvSuffix();
        string memory cfg = vm.readFile(_releaseConfigPath(c.env));
        string memory l2Manifest = vm.readFile(_manifestPath(c.env, false));

        c.deployer = vm.envAddress("DEPLOYER");
        c.upgrader = _optionalSigner("UPGRADER", c.deployer);
        c.wirer = vm.envAddress("WIRER");
        c.targetNonce = _targetNonceForEnv(c.env);

        c.bridge = _readAddr(l2Manifest, "bridge");
        c.erc20 = _readAddr(l2Manifest, "erc20_gateway");
        c.factory = _readAddr(l2Manifest, "factory");
        c.gatewayOwner = _readAddr(cfg, "gateway_initial_owner");
        c.l1Weth = _readAddr(cfg, "l1_weth");

        require(c.bridge != address(0) && c.bridge.code.length > 0, "l2 bridge missing");
        require(c.erc20 != address(0) && c.erc20.code.length > 0, "l2 erc20 gateway missing");
        require(c.factory != address(0) && c.factory.code.length > 0, "l2 factory missing");
        require(c.gatewayOwner != address(0), "gateway_initial_owner missing");
        require(c.l1Weth != address(0), "l1_weth missing");

        vm.startBroadcast(c.deployer);
        _bumpNonceTo(c.targetNonce, c.deployer);
        (address impl, address proxy) = _deployGateway(c.bridge, c.gatewayOwner);
        vm.stopBroadcast();

        vm.startBroadcast(c.upgrader);
        _upgradeL2ERC20Gateway(c.erc20);
        _upgradeL2Factory(c.factory);
        address universalWeth = _deployUniversalWeth(c.factory, proxy, c.l1Weth);
        vm.stopBroadcast();

        vm.startBroadcast(c.wirer);
        WETHGateway(payable(proxy)).setOtherSideGateway(proxy);
        L2FluentBridge(payable(c.bridge)).registerGateway(proxy);
        WETHGateway(payable(proxy)).setWETH(universalWeth);
        vm.stopBroadcast();

        console2.log("L2 flow complete for env:", c.env);
        console2.log("  deployer          :", c.deployer);
        console2.log("  upgrader          :", c.upgrader);
        console2.log("  wirer             :", c.wirer);
        console2.log("  target nonce      :", c.targetNonce);
        console2.log("  gateway impl      :", impl);
        console2.log("  gateway proxy     :", proxy);
        console2.log("  universal_weth_l2 :", universalWeth);
        console2.log("Update release_weth.json universal_weth_l2 with this value.");
    }

    function _upgradeL2ERC20Gateway(address erc20) internal {
        address newImpl = address(new ERC20Gateway());
        UnsafeUpgrades.upgradeProxy(payable(erc20), newImpl, "");
    }

    function _upgradeL2Factory(address factory) internal {
        address newImpl = address(new UniversalTokenFactory());
        UnsafeUpgrades.upgradeProxy(payable(factory), newImpl, "");
    }

    function _deployUniversalWeth(address factory, address wethGateway, address l1Weth) internal returns (address) {
        // address existing = UniversalTokenFactory(factory).bridgedTokens(l1Weth);
        // if (existing != address(0)) return existing;
        bytes memory deployArgs = abi.encode("Wrapped Ether", "WETH", uint8(18), uint256(0), address(0), address(0), true);
        return UniversalTokenFactory(factory).deployToken(wethGateway, l1Weth, deployArgs);
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
