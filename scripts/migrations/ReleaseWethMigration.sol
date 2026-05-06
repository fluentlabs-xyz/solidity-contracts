// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";

import {DeployBase} from "../deploy/DeployBase.s.sol";

/// @title ReleaseWethMigration
/// @author Fluent Labs
///
/// @notice WETH release - **proxy-owner side**. Upgrades {ERC20Gateway} on both chains,
///         excludes L1 WETH from the generic ERC20 bridging path, upgrades
///         {UniversalTokenFactory} on L2, then deploys the Universal-WETH token via that
///         factory so the L2 `WETHGateway` has something to wrap/unwrap against.
///
/// @dev This script is intentionally scoped to actions the **existing-proxy owner** must
///      perform (upgrades + factory-gated token deploy). The new {WETHGateway} proxies
///      themselves are deployed at a deterministic, cross-chain-matching address by
///      {DeployWETHGatewayBase} (see `scripts/deploy/DeployWETHGateway.s.sol`); all
///      peer/bridge wiring (`setWETH` / `setOtherSideGateway` / `registerGateway`) lives
///      in that script's `wireL1()` / `wireL2()` / `wireL2WETH()` entrypoints and runs
///      from the `gateway_initial_owner` + bridge-admin key.
///
/// @dev Ordering (run each on the matching RPC with `--broadcast`, from the proxy owner):
///        1. {DeployWETHGatewayBase.deployL1} + {DeployWETHGatewayBase.deployL2} produce
///           the shared `WETHGateway` proxy address — record it as `weth_gateway` in
///           `release_weth.json` before running this script.
///        2. `deployL1()` — Upgrade L1 {ERC20Gateway}; call `setBridgingExcludedOrigin`
///           on the configured L1 WETH origin so the generic path rejects it.
///        3. `deployL2()` — Upgrade L2 {ERC20Gateway} + {UniversalTokenFactory}; deploy
///           Universal-WETH using the shared `weth_gateway` address as the salt input
///           and `l1_weth` as the origin. Record the resulting token as
///           `universal_weth_l2` so {DeployWETHGatewayBase.wireL2WETH} can wire it.
///
///      Universal-WETH CREATE2 salt is `keccak256(abi.encodePacked(weth_gateway, l1_weth))`
///      — identical on L1 and L2 because the gateway address is identical — so the token
///      lands at a deterministic address driven by the factory proxy and the WETH
///      gateway's address.
///
/// @dev Subclasses set `_deploymentManifestEnv()` (`testnet` / `mainnet`) and
///      `_releaseConfigPath()` (e.g. `scripts/config/testnet/release_weth.json`).
abstract contract ReleaseWethMigration is DeployBase {
    /// @dev `deployments/<env>/l1.json` and `deployments/<env>/l2.json` directory name.
    function _deploymentManifestEnv() internal pure virtual returns (string memory);

    /// @dev Full path to `release_weth.json` for this environment.
    function _releaseConfigPath() internal pure virtual returns (string memory);

    // ============ Public entrypoints ============

    /// @notice L1 chain: upgrade {ERC20Gateway} and exclude L1 WETH from the generic path.
    function deployL1() public virtual {
        string memory cfg = vm.readFile(_releaseConfigPath());

        vm.startBroadcast();
        _upgradeL1ERC20Gateway(cfg);
        vm.stopBroadcast();
    }

    /// @notice L2 chain: upgrade {ERC20Gateway} + {UniversalTokenFactory}, then deploy
    ///         Universal-WETH through the new factory.
    function deployL2() public virtual {
        string memory cfg = vm.readFile(_releaseConfigPath());

        vm.startBroadcast();
        //        _upgradeL2ERC20Gateway();
        //        _upgradeL2Factory();
        _deployUniversalWETH(cfg);
        vm.stopBroadcast();
    }

    // ============ Internal steps ============

    function _upgradeL1ERC20Gateway(string memory cfg) internal {
        string memory manifest = vm.readFile(string.concat("deployments/", _deploymentManifestEnv(), "/l1.json"));
        address payable erc20 = payable(_readAddr(manifest, "erc20_gateway"));
        require(erc20 != address(0), "l1.erc20_gateway missing");
        require(erc20.code.length > 0, "L1 ERC20Gateway proxy has no code");

        address newImpl = address(new ERC20Gateway());
        UnsafeUpgrades.upgradeProxy(erc20, newImpl, "");

        // Origin of L1 WETH — the generic ERC20 path must reject this token so users route
        // through the dedicated {WETHGateway}, otherwise a second pegged WETH address would
        // appear on L2 and diverge from the Universal-WETH this gateway targets.
        address exclude = _readAddr(cfg, "bridging_exclude_l1_weth");
        if (exclude == address(0)) exclude = _readAddr(cfg, "l1_weth");
        require(exclude != address(0), "release_weth.json: set l1_weth or bridging_exclude_l1_weth");
        ERC20Gateway(erc20).setBridgingExcludedOrigin(exclude, true);

        console2.log("L1 ERC20Gateway upgraded");
        console2.log("  proxy         :", erc20);
        console2.log("  impl          :", newImpl);
        console2.log("  excluded origin:", exclude);
    }

    function _upgradeL2ERC20Gateway() internal {
        string memory manifest = vm.readFile(string.concat("deployments/", _deploymentManifestEnv(), "/l2.json"));
        address payable erc20 = payable(_readAddr(manifest, "erc20_gateway"));
        require(erc20 != address(0), "l2.erc20_gateway missing");
        require(erc20.code.length > 0, "L2 ERC20Gateway proxy has no code");

        address newImpl = address(new ERC20Gateway());
        UnsafeUpgrades.upgradeProxy(erc20, newImpl, "");

        console2.log("L2 ERC20Gateway upgraded");
        console2.log("  proxy:", erc20);
        console2.log("  impl :", newImpl);
    }

    function _upgradeL2Factory() internal {
        string memory manifest = vm.readFile(string.concat("deployments/", _deploymentManifestEnv(), "/l2.json"));
        address payable factory = payable(_readAddr(manifest, "factory"));
        require(factory != address(0), "l2.factory missing");
        require(factory.code.length > 0, "L2 UniversalTokenFactory proxy has no code");

        address newImpl = address(new UniversalTokenFactory());
        UnsafeUpgrades.upgradeProxy(factory, newImpl, "");

        console2.log("L2 UniversalTokenFactory upgraded");
        console2.log("  proxy:", factory);
        console2.log("  impl :", newImpl);
    }

    /// @dev Deploys Universal-WETH via the (now upgraded) {UniversalTokenFactory}. Must
    ///      run after {_upgradeL2Factory} so the `wrapped` flag in `deployArgs` is
    ///      understood by the factory. The gateway arg to `deployToken` is the shared
    ///      `weth_gateway` address (same on L1 and L2) — it's used as the CREATE2 salt
    ///      input, so the Universal-WETH lands at a fully deterministic address.
    function _deployUniversalWETH(string memory cfg) internal {
        string memory manifest = vm.readFile(string.concat("deployments/", _deploymentManifestEnv(), "/l2.json"));
        address factory = _readAddr(manifest, "factory");
        address wethGateway = _readAddr(cfg, "weth_gateway");
        address l1Weth = _readAddr(cfg, "l1_weth");
        require(factory != address(0) && factory.code.length > 0, "L2 factory missing");
        require(wethGateway != address(0), "release_weth.json: weth_gateway required (run DeployWETHGateway.predict() and record)");
        require(l1Weth != address(0), "release_weth.json: l1_weth required");

        // deployArgs layout: (name, symbol, decimals, initialSupply, minter, pauser, wrapped)
        // For wrapped=true the factory requires minter=address(0) and initialSupply=0.
        bytes memory deployArgs = abi.encode("Wrapped Ether", "WETH", uint8(18), uint256(0), address(0), address(0), true);
        console2.log("DEPLOY PARAMS: ");
        console2.logBytes(deployArgs);
        address universalWeth = UniversalTokenFactory(factory).deployToken(wethGateway, l1Weth, deployArgs);

        console2.log("Universal-WETH deployed on L2");
        console2.log("  factory (deployer): ", factory);
        console2.log("  weth_gateway (salt):", wethGateway);
        console2.log("  l1_weth (origin)   :", l1Weth);
        console2.log("  universal_weth_l2  :", universalWeth);
        console2.log("Record universal_weth_l2 in release_weth.json, then run DeployWETHGateway.wireL2WETH()");
    }
}
