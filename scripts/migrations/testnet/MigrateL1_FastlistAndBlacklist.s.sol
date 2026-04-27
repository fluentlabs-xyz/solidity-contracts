// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Blacklist} from "../../../contracts/blacklist/Blacklist.sol";
import {L1FluentBridge} from "../../../contracts/bridge/L1/L1FluentBridge.sol";
import {ERC20Gateway} from "../../../contracts/gateways/ERC20Gateway.sol";
import {NativeGateway} from "../../../contracts/gateways/NativeGateway.sol";
import {FastWithdrawalList} from "../../../contracts/fastlist/FastWithdrawalList.sol";

import {DeployBase} from "../../deploy/DeployBase.s.sol";

/// @dev Rate-limit row for {FastWithdrawalList} (same semantics as mainnet fastlist migration).
struct FastWithdrawalTokenConfig {
    address token;
    string symbol;
    uint256 hourlyLimit;
    uint256 dailyLimit;
    address aliasOf;
}

/**
 * @title MigrateL1_FastlistAndBlacklist
 * @notice **Sepolia / L1 testnet** one-shot migration that runs, in order:
 *           1. **Fastlist** — same logical steps as {MigrateL1_Fastlist} on mainnet: deploy
 *              {FastWithdrawalList} (UUPS proxy), upgrade {L1FluentBridge}, {ERC20Gateway},
 *              and {NativeGateway}, wire the list, grant `CONSUMER_ROLE`, register local +
 *              remote gateways on the bridge, then register test tokens (native bucket,
 *              manifest `weth_token` aliased to native, optional `mock_token` bucket).
 *           2. **Blacklist** — deploy {Blacklist} (UUPS proxy), seed from a text file, wire
 *              both gateways via {GatewayBase.setBlacklistRegistry}.
 *
 * @dev Environment:
 *        `ENV` (optional, default `testnet`) — reads `deployments/<ENV>/l1.json` and `l2.json`.
 *        `INITIAL_OWNER` (required) — Ownable owner for the new {Blacklist} **and** initializer
 *             owner for {FastWithdrawalList}; must also own both L1 gateways so wiring + seeding
 *             succeed in one broadcast (same model as {MigrateL1_Blacklist}).
 *        `BLACKLIST_FILE` (optional) — path to `0x` + 40-hex lines; defaults to
 *             `scripts/config/blacklist/black_list_eth.txt`.
 *        `WIRE_GATEWAYS` (optional, default `true`) — when `false`, skips blacklist gateway wiring
 *             only (fastlist gateway wiring still runs; use only if you know you need it).
 *
 * @dev This script does **not** enable fast-withdrawal whitelist mode on gateways. After the run,
 *      enable separately: `erc20Gateway.setWhitelistEnabled(true)` and
 *      `nativeGateway.setWhitelistEnabled(true)`.
 *
 * @dev Does not update deployment manifests; operator copies logged proxy / impl addresses into
 *      `deployments/<ENV>/l1.json` (`fast_withdrawal_list_*`, `blacklist_*`, and upgraded `*_impl`
 *      keys as applicable).
 */
contract MigrateL1_FastlistAndBlacklist is DeployBase {
    using stdJson for string;

    string internal constant DEFAULT_BLACKLIST_PATH = "scripts/config/blacklist/black_list_eth.txt";

    /// @dev Mirror of `NativeGateway.NATIVE_LIMIT_KEY` for compile-time registration rows.
    address internal constant NATIVE_LIMIT_KEY = address(0x0000012345678901234567890123456789012345);

    struct L1Addresses {
        address payable bridge;
        address payable erc20Gateway;
        address payable nativeGateway;
        address payable remoteErc20Gateway;
        address payable remoteNativeGateway;
        address owner;
        address weth;
        address mockToken;
    }

    function run() external {
        string memory env = vm.envOr("ENV", string("testnet"));
        L1Addresses memory addrs = _loadAddresses(env);
        string memory listPath = vm.envOr("BLACKLIST_FILE", DEFAULT_BLACKLIST_PATH);
        bool wireBlacklistOnGateways = vm.envOr("WIRE_GATEWAYS", true);

        address[] memory blacklistEntries = _loadBlacklistFile(listPath);
        require(blacklistEntries.length > 0, "blacklist file produced zero addresses; refusing to migrate");

        if (wireBlacklistOnGateways) {
            require(addrs.erc20Gateway != address(0) && addrs.nativeGateway != address(0), "gateways missing");
        }

        _logPlan(env, addrs, listPath, blacklistEntries.length, wireBlacklistOnGateways);

        vm.startBroadcast();

        // ----- Phase A: Fastlist -----
        FastWithdrawalList listImpl = new FastWithdrawalList();
        ERC1967Proxy listProxy = new ERC1967Proxy(
            address(listImpl), abi.encodeCall(FastWithdrawalList.initialize, (addrs.owner))
        );
        FastWithdrawalList list = FastWithdrawalList(address(listProxy));
        console2.log("FastWithdrawalList proxy:", address(list));
        console2.log("FastWithdrawalList impl :", address(listImpl));

        address newBridgeImpl = address(new L1FluentBridge());
        UnsafeUpgrades.upgradeProxy(addrs.bridge, newBridgeImpl, "");
        console2.log("L1FluentBridge:", addrs.bridge, "->", newBridgeImpl);

        address newErc20GatewayImpl = address(new ERC20Gateway());
        UnsafeUpgrades.upgradeProxy(addrs.erc20Gateway, newErc20GatewayImpl, "");
        console2.log("ERC20Gateway:  ", addrs.erc20Gateway, "->", newErc20GatewayImpl);

        NativeGateway newNativeGatewayImpl = new NativeGateway();
        require(
            newNativeGatewayImpl.NATIVE_LIMIT_KEY() == NATIVE_LIMIT_KEY,
            "NATIVE_LIMIT_KEY mismatch between script and new NativeGateway impl"
        );
        UnsafeUpgrades.upgradeProxy(addrs.nativeGateway, address(newNativeGatewayImpl), "");
        console2.log("NativeGateway: ", addrs.nativeGateway, "->", address(newNativeGatewayImpl));

        ERC20Gateway(addrs.erc20Gateway).setFastWithdrawalList(address(list));
        NativeGateway(addrs.nativeGateway).setFastWithdrawalList(address(list));
        console2.log("setFastWithdrawalList: erc20Gateway, nativeGateway");

        bytes32 consumerRole = list.CONSUMER_ROLE();
        list.grantRole(consumerRole, addrs.erc20Gateway);
        list.grantRole(consumerRole, addrs.nativeGateway);
        console2.log("grantRole(CONSUMER_ROLE): erc20Gateway, nativeGateway");

        L1FluentBridge bridge = L1FluentBridge(addrs.bridge);
        bridge.registerGateway(addrs.erc20Gateway);
        bridge.registerGateway(addrs.nativeGateway);
        console2.log("registerGateway (local): erc20Gateway, nativeGateway");
        bridge.registerGateway(addrs.remoteErc20Gateway);
        bridge.registerGateway(addrs.remoteNativeGateway);
        console2.log("registerGateway (remote): erc20Gateway, nativeGateway");

        _registerFastWithdrawalTokens(list, addrs.weth, addrs.mockToken);

        // ----- Phase B: Blacklist -----
        Blacklist blImpl = new Blacklist();
        ERC1967Proxy blProxy = new ERC1967Proxy(
            address(blImpl), abi.encodeCall(Blacklist.initialize, (addrs.owner))
        );
        Blacklist blacklist = Blacklist(address(blProxy));
        console2.log("Blacklist proxy:", address(blacklist));
        console2.log("Blacklist impl :", address(blImpl));

        blacklist.setBlacklistedBatch(blacklistEntries, true);
        console2.log("Seeded blacklist entries:", blacklistEntries.length);

        if (wireBlacklistOnGateways) {
            ERC20Gateway(addrs.erc20Gateway).setBlacklistRegistry(address(blacklist));
            console2.log("ERC20Gateway.setBlacklistRegistry:  ", addrs.erc20Gateway);
            NativeGateway(addrs.nativeGateway).setBlacklistRegistry(address(blacklist));
            console2.log("NativeGateway.setBlacklistRegistry: ", addrs.nativeGateway);
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("== Migration complete ==");
        console2.log("Fast-withdrawal whitelist is NOT enabled yet (setWhitelistEnabled on gateways).");
        if (!wireBlacklistOnGateways) {
            console2.log("Blacklist gateway wiring skipped (WIRE_GATEWAYS=false).");
            console2.log("  Call setBlacklistRegistry(", address(blacklist), ") from each gateway owner.");
        }
        console2.log("Update deployments/", env, "/l1.json with:");
        console2.log("  fast_withdrawal_list_proxy ->", address(list));
        console2.log("  fast_withdrawal_list_impl  ->", address(listImpl));
        console2.log("  blacklist_proxy              ->", address(blacklist));
        console2.log("  blacklist_impl             ->", address(blImpl));
        console2.log("  bridge_impl / erc20_gateway_impl / native_gateway_impl -> logged impls above");
    }

    function _fastWithdrawalTokenConfigs(address weth, address mockToken)
        internal
        pure
        returns (FastWithdrawalTokenConfig[] memory configs)
    {
        uint256 n = mockToken == address(0) ? uint256(2) : uint256(3);
        configs = new FastWithdrawalTokenConfig[](n);

        // Testnet-friendly caps (not production USD targets).
        configs[0] = FastWithdrawalTokenConfig({
            token: NATIVE_LIMIT_KEY,
            symbol: "ETH",
            hourlyLimit: 1_000 ether,
            dailyLimit: 10_000 ether,
            aliasOf: address(0)
        });

        require(weth != address(0), "weth_token missing in l1 manifest");
        configs[1] = FastWithdrawalTokenConfig({token: weth, symbol: "WETH", hourlyLimit: 0, dailyLimit: 0, aliasOf: NATIVE_LIMIT_KEY});

        if (mockToken != address(0)) {
            configs[2] = FastWithdrawalTokenConfig({
                token: mockToken,
                symbol: "MOCK",
                hourlyLimit: 1_000_000 ether,
                dailyLimit: 10_000_000 ether,
                aliasOf: address(0)
            });
        }
    }

    function _registerFastWithdrawalTokens(FastWithdrawalList list, address weth, address mockToken) internal {
        FastWithdrawalTokenConfig[] memory configs = _fastWithdrawalTokenConfigs(weth, mockToken);
        for (uint256 i = 0; i < configs.length; ++i) {
            FastWithdrawalTokenConfig memory cfg = configs[i];
            require(cfg.token != address(0), string.concat("fast-withdrawal token address missing: ", cfg.symbol));

            if (cfg.aliasOf == address(0)) {
                list.registerToken(cfg.token, cfg.hourlyLimit, cfg.dailyLimit);
                console2.log("registerToken:", cfg.symbol, cfg.token);
            } else {
                require(cfg.hourlyLimit == 0 && cfg.dailyLimit == 0, string.concat("alias row must not carry limits: ", cfg.symbol));
                list.setAlias(cfg.token, cfg.aliasOf);
                console2.log("setAlias:", cfg.symbol, cfg.token);
                console2.log("  -> bucket:", cfg.aliasOf);
            }
        }
    }

    function _loadAddresses(string memory env) internal view returns (L1Addresses memory addrs) {
        string memory l1Manifest = vm.readFile(string.concat("deployments/", env, "/l1.json"));
        string memory l2Manifest = vm.readFile(string.concat("deployments/", env, "/l2.json"));

        addrs.bridge = payable(_readAddr(l1Manifest, "bridge"));
        addrs.erc20Gateway = payable(_readAddr(l1Manifest, "erc20_gateway"));
        addrs.nativeGateway = payable(_readAddr(l1Manifest, "native_gateway"));
        addrs.remoteErc20Gateway = payable(_readAddr(l2Manifest, "erc20_gateway"));
        addrs.remoteNativeGateway = payable(_readAddr(l2Manifest, "native_gateway"));
        addrs.owner = vm.envAddress("INITIAL_OWNER");
        addrs.weth = _readAddr(l1Manifest, "weth_token");
        addrs.mockToken = _readAddr(l1Manifest, "mock_token");

        require(addrs.bridge != address(0), "L1 bridge address missing in manifest");
        require(addrs.erc20Gateway != address(0), "L1 erc20_gateway address missing in manifest");
        require(addrs.nativeGateway != address(0), "L1 native_gateway address missing in manifest");
        require(addrs.remoteErc20Gateway != address(0), "L2 erc20_gateway address missing in manifest");
        require(addrs.remoteNativeGateway != address(0), "L2 native_gateway address missing in manifest");
        require(addrs.owner != address(0), "INITIAL_OWNER required");
    }

    function _logPlan(
        string memory env,
        L1Addresses memory addrs,
        string memory listPath,
        uint256 blacklistCount,
        bool wireBlacklistOnGateways
    ) internal pure {
        console2.log("== MigrateL1_FastlistAndBlacklist (testnet) ==");
        console2.log("env:                  ", env);
        console2.log("L1 bridge:            ", addrs.bridge);
        console2.log("L1 erc20Gateway:      ", addrs.erc20Gateway);
        console2.log("L1 nativeGateway:     ", addrs.nativeGateway);
        console2.log("L2 erc20Gateway:      ", addrs.remoteErc20Gateway);
        console2.log("L2 nativeGateway:     ", addrs.remoteNativeGateway);
        console2.log("Owner (lists + gates):", addrs.owner);
        console2.log("WETH (manifest):      ", addrs.weth);
        console2.log("Mock token:          ", addrs.mockToken);
        console2.log("Blacklist file:      ", listPath);
        console2.log("Blacklist entries:   ", blacklistCount);
        console2.log("Wire blacklist on gw:", wireBlacklistOnGateways);
        console2.log("");
    }

    function _loadBlacklistFile(string memory path) internal view returns (address[] memory entries) {
        string memory text = vm.readFile(path);
        string[] memory lines = vm.split(text, "\n");

        uint256 count;
        for (uint256 i = 0; i < lines.length; i++) {
            if (_isEvmAddressLine(lines[i])) count++;
        }
        entries = new address[](count);

        uint256 idx;
        for (uint256 i = 0; i < lines.length; i++) {
            if (!_isEvmAddressLine(lines[i])) continue;
            entries[idx++] = vm.parseAddress(lines[i]);
        }
    }

    function _isEvmAddressLine(string memory line) internal pure returns (bool) {
        bytes memory b = bytes(line);
        if (b.length != 42) return false;
        if (b[0] != bytes1("0")) return false;
        if (b[1] != bytes1("x") && b[1] != bytes1("X")) return false;
        return true;
    }
}
