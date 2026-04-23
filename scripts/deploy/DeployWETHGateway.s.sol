// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {console2} from "forge-std/console2.sol";

import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {WETHGateway} from "../../contracts/gateways/WETHGateway.sol";

import {DeployBase} from "./DeployBase.s.sol";

/// @title DeployWETHGatewayBase
/// @author Fluent Labs
///
/// @notice Stand-alone {WETHGateway} deploy that lands the proxy at the **same CREATE
///         address on L1 and L2** by aligning the deployer EOA's nonce across chains
///         before the impl/proxy creations.
///
/// @dev Determinism contract (plain `CREATE`):
///      An EOA CREATE address is `keccak256(rlp(sender, nonce))[12:]`. For the impl and
///      proxy to land at the same address on every chain, the deploy must run from the
///      **same EOA** with the **same nonce** at the start of each deployment. The script
///      burns spare nonces by sending 0-ETH self-transfers (21k gas each, no contract
///      deployment) until `nonce(tx.origin) == _targetNonce()`, then:
///
///        - impl  = CREATE(tx.origin, _targetNonce())       — `new WETHGateway()`
///        - proxy = CREATE(tx.origin, _targetNonce() + 1)   — `new ERC1967Proxy(impl, initData)`
///
///      The proxy's `initData` must also be byte-identical across chains. Both chains
///      use the same `gateway_initial_owner` (from `release_weth.json`) and the same
///      bridge address (already identical in `deployments/<env>/{l1,l2}.json`), with
///      `wethContract = address(0)` so the init payload matches on both sides. WETH is
///      wired afterwards via the owner-only {WETHGateway.setWETH} setter.
///
/// @dev Role split:
///      The deployer EOA owns the existing proxies (e.g. {ERC20Gateway},
///      {UniversalTokenFactory}) and is the natural party to burn nonces + deploy, but
///      it is **not** the gateway owner nor a bridge admin. The new {WETHGateway} proxy
///      is initialized with `owner = gateway_initial_owner`; `setWETH` /
///      `setOtherSideGateway` / `registerGateway` must therefore be executed from the
///      gateway-owner + bridge-admin key via {wireL1} / {wireL2} / {wireL2WETH}.
///
/// @dev Expected operator flow:
///        1. (deployer key) `deployL1()`    — Sepolia / Ethereum mainnet
///        2. (deployer key) `deployL2()`    — Fluent testnet / mainnet
///        3. (wiring key)   `wireL1()`      — L1 `setWETH(l1_weth)`, `setOtherSideGateway(self)`,
///                                            `L1FluentBridge.registerGateway(self)`
///        4. (wiring key)   `wireL2()`      — L2 `setOtherSideGateway(self)`,
///                                            `L2FluentBridge.registerGateway(self)`
///        5. (factory owner, out of band)   Deploy Universal-WETH on L2 with
///                                            `gateway = <this proxy>` and
///                                            `originToken = l1_weth`. Record it in
///                                            `release_weth.json` as `universal_weth_l2`.
///        6. (wiring key)   `wireL2WETH()`  — L2 `setWETH(universal_weth_l2)`
abstract contract DeployWETHGatewayBase is DeployBase {
    // ============ Configuration hooks ============

    /// @dev `deployments/<env>/l1.json` and `deployments/<env>/l2.json` directory name.
    function _deploymentManifestEnv() internal pure virtual returns (string memory);

    /// @dev Full path to `release_weth.json` for this environment.
    function _releaseConfigPath() internal pure virtual returns (string memory);

    /// @dev Nonce the deployer EOA must reach before broadcasting the impl deploy. Pick
    ///      a value `>= max(nonce(deployer, l1), nonce(deployer, l2))` at execution time;
    ///      bump it in the subclass if either chain's nonce has advanced since the last
    ///      plan. A sensible default is the higher of the two current nonces — the
    ///      lower-nonce chain pays for the extra {Nop} deployments.
    function _targetNonce() internal pure virtual returns (uint256);

    // ============ Deploy entrypoints (run as the deployer EOA) ============

    /// @notice L1 chain: bump deployer nonce to target, then `new WETHGateway()` +
    ///         `new ERC1967Proxy(impl, init)` via plain CREATE.
    function deployL1() public virtual {
        (address bridge, address gatewayOwner) = _readSide(true);

        vm.startBroadcast();
        _bumpNonceTo(_targetNonce());
        (address impl, address proxy) = _deployGateway(bridge, gatewayOwner);
        vm.stopBroadcast();

        _logDeploy("WETH_GATEWAY_L1", impl, proxy, bridge, gatewayOwner);
    }

    /// @notice L2 chain: same structure as {deployL1}; the matching nonce gives the same
    ///         proxy address.
    function deployL2() public virtual {
        (address bridge, address gatewayOwner) = _readSide(false);

        vm.startBroadcast();
        _bumpNonceTo(_targetNonce());
        (address impl, address proxy) = _deployGateway(bridge, gatewayOwner);
        vm.stopBroadcast();

        _logDeploy("WETH_GATEWAY_L2", impl, proxy, bridge, gatewayOwner);
    }

    // ============ Wiring entrypoints (run as `gateway_initial_owner` + bridge admin) ============

    /// @notice L1 wire-up: `setWETH`, `setOtherSideGateway(self)`, bridge `registerGateway`.
    function wireL1() public virtual {
        (address bridge, ) = _readSide(true);
        string memory cfg = vm.readFile(_releaseConfigPath());
        address l1Weth = _readAddr(cfg, "l1_weth");
        console2.log("BRIDGE: ");
        console2.logAddress(bridge);
        console2.log("WETH: ");
        console2.logAddress(l1Weth);
        require(l1Weth != address(0) && l1Weth.code.length > 0, "release_weth.json: l1_weth has no code");

        address proxy = 0x9C2baa1d32466aceC1AdDD98AA047fB7B6D55622; //_predictProxy();
        require(proxy.code.length > 0, "L1 WETHGateway proxy not deployed yet");

        vm.startBroadcast();
        WETHGateway(payable(proxy)).setWETH(l1Weth);
        WETHGateway(payable(proxy)).setOtherSideGateway(proxy);
//        L1FluentBridge(payable(bridge)).registerGateway(proxy);
        vm.stopBroadcast();

        console2.log("L1 WETHGateway wired:", proxy);
    }

    /// @notice L2 wire-up: `setOtherSideGateway(self)` + bridge `registerGateway`. WETH
    ///         is wired separately by {wireL2WETH} after Universal-WETH exists.
    function wireL2() public virtual {
        (address bridge, ) = _readSide(false);
        address proxy = 0x9C2baa1d32466aceC1AdDD98AA047fB7B6D55622; //_predictProxy();
        require(proxy.code.length > 0, "L2 WETHGateway proxy not deployed yet");

        vm.startBroadcast();
        WETHGateway(payable(proxy)).setOtherSideGateway(proxy);
//        L2FluentBridge(payable(bridge)).registerGateway(proxy);
        vm.stopBroadcast();

        console2.log("L2 WETHGateway wired:", proxy);
    }

    /// @notice L2 post-Universal-WETH wire-up: `setWETH(universal_weth_l2)` on the L2 proxy.
    function wireL2WETH() public virtual {
        string memory cfg = vm.readFile(_releaseConfigPath());
        address universalWeth = _readAddr(cfg, "universal_weth_l2");
        require(universalWeth != address(0) && universalWeth.code.length > 0, "release_weth.json: universal_weth_l2 has no code");

        address proxy = 0x9C2baa1d32466aceC1AdDD98AA047fB7B6D55622; //_predictProxy();
        require(proxy.code.length > 0, "L2 WETHGateway proxy not deployed yet");

        vm.startBroadcast();
        WETHGateway(payable(proxy)).setWETH(universalWeth);
        vm.stopBroadcast();

        console2.log("L2 WETHGateway WETH set:");
        console2.log("  proxy:", proxy);
        console2.log("  weth :", universalWeth);
    }

    // ============ Read-only helpers ============

    /// @notice Prints the CREATE-predicted proxy/impl for the configured `_targetNonce()`
    ///         (does not depend on chain state other than the deployer address supplied
    ///         via `--sender`).
    function predict() public view {
        address deployer = tx.origin;
        uint256 t = _targetNonce();
        address impl = vm.computeCreateAddress(deployer, t);
        address proxy = vm.computeCreateAddress(deployer, t + 1);
        console2.log("Deployer         :", deployer);
        console2.log("Target nonce     :", t);
        console2.log("Predicted impl   :", impl);
        console2.log("Predicted proxy  :", proxy);
    }

    // ============ Internal ============

    function _readSide(bool isL1) internal view returns (address bridge, address gatewayOwner) {
        string memory manifest = vm.readFile(string.concat("deployments/", _deploymentManifestEnv(), isL1 ? "/l1.json" : "/l2.json"));
        string memory cfg = vm.readFile(_releaseConfigPath());
        bridge = _readAddr(manifest, "bridge");
        gatewayOwner = _readAddr(cfg, "gateway_initial_owner");
        require(bridge != address(0) && bridge.code.length > 0, "bridge missing");
        require(gatewayOwner != address(0), "release_weth.json: gateway_initial_owner required");
    }

    function _deployGateway(address bridge, address gatewayOwner) internal returns (address impl, address proxy) {
        impl = address(new WETHGateway());
        bytes memory initData = abi.encodeCall(WETHGateway.initialize, (gatewayOwner, bridge, address(0)));
        proxy = address(new ERC1967Proxy(impl, initData));
    }

    /// @dev Burns nonces by sending 0-ETH self-transfers until the signer EOA reaches
    ///      `target`. Each self-send under broadcast is a plain value-transfer tx from
    ///      the signer to itself (21k gas, no contract deployment), incrementing the
    ///      nonce by exactly one. Reverts if the signer is already past `target`
    ///      (indicating the subclass constant needs to be bumped to match the new chain
    ///      state).
    function _bumpNonceTo(uint256 target) internal {
        address deployer = tx.origin;
        uint256 cur = vm.getNonce(deployer);
        require(
            cur <= target,
            string.concat(
                "deployer nonce already past target: cur=",
                vm.toString(cur),
                " target=",
                vm.toString(target),
                " - bump _targetNonce() in the subclass"
            )
        );
        uint256 burned;
        while (cur < target) {
            (bool ok, ) = payable(deployer).call{value: 0}("");
            require(ok, "nonce-burn self-send failed");
            unchecked {
                cur += 1;
                burned += 1;
            }
        }
        if (burned > 0) {
            console2.log("Bumped deployer nonce by", burned);
            console2.log("  deployer:", deployer);
            console2.log("  target  :", target);
        }
    }

    /// @dev The proxy CREATE address is independent of chain state: `CREATE(tx.origin,
    ///      _targetNonce() + 1)`. Wire-up functions use this to reach the deployed
    ///      gateway on either chain.
    function _predictProxy() internal view returns (address) {
        return vm.computeCreateAddress(tx.origin, _targetNonce() + 1);
    }

    function _logDeploy(string memory label, address impl, address proxy, address bridge, address gatewayOwner) internal pure {
        console2.log(label, "(proxy):", proxy);
        console2.log("  impl  :", impl);
        console2.log("  owner :", gatewayOwner);
        console2.log("  bridge:", bridge);
    }
}
