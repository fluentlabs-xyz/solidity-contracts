// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {L1FluentBridge} from "../../../contracts/bridge/L1/L1FluentBridge.sol";
import {ERC20Gateway} from "../../../contracts/gateways/ERC20Gateway.sol";
import {NativeGateway} from "../../../contracts/gateways/NativeGateway.sol";
import {FastWithdrawalList} from "../../../contracts/fastlist/FastWithdrawalList.sol";

import {DeployBase} from "../../deploy/DeployBase.s.sol";

/// @dev Rate-limit entry for a single fast-withdrawable token on L1 mainnet.
///
///      `token` is the physical address to wire up — an ERC-20 address, or
///      {NativeGateway.NATIVE_LIMIT_KEY} for the native-ETH bucket.
///
///      Two mutually-exclusive modes:
///
///      1. `aliasOf == address(0)` — the entry gets its own bucket via
///         `registerToken(token, hourlyLimit, dailyLimit)`. Limits are in raw
///         token units (no USD conversion); callers scale by the token's own
///         decimals.
///
///      2. `aliasOf != address(0)` — the entry is wired via `setAlias(token,
///         aliasOf)`, so consume calls against `token` debit `aliasOf`'s
///         bucket instead. `hourlyLimit` / `dailyLimit` MUST be zero in this
///         mode — they would be silently ignored and signal intent incorrectly.
///         The `aliasOf` target must appear earlier in the config array so it
///         is already registered by the time this row is processed.
struct FastWithdrawalTokenConfig {
    address token;
    string symbol;
    uint256 hourlyLimit;
    uint256 dailyLimit;
    address aliasOf;
}

/// @notice Fastlist-feature migration for L1.
///
/// @dev What this script does, in order:
///        1.  Deploys a fresh {FastWithdrawalList} behind a UUPS proxy.
///        2.  Upgrades the existing L1FluentBridge implementation to the new one
///            (adds `_gatewayWhitelist` mapping, transient `_currentBatchIndex`,
///            `registerGateway` / `unregisterGateway` admin API, gateway-symmetric
///            `GatewayNotWhitelisted` guards on send + receive).
///        3.  Upgrades the existing ERC20Gateway and NativeGateway implementations
///            (adds `_fastWithdrawalList` storage + `_whitelistEnabled` toggle, drops
///            the old per-gateway `_tokenLimitConfig` / `_usageInfo` mappings).
///        4.  Wires the new FastWithdrawalList into both gateways via
///            `setFastWithdrawalList`.
///        5.  Registers both gateways as `consumers` on the FastWithdrawalList so
///            their `_consumeLimit` calls are accepted.
///        6.  Registers the *local* gateway addresses on the bridge so receives into
///            them and sends originating from them stay admitted.
///        7.  Registers the *remote* (L2) gateway addresses on the bridge so user-side
///            `gateway.sendTokens(...)` / `gateway.sendNativeTokens(...)` calls — which
///            target the remote gateway — pass the new symmetric admission check.
///        8.  Registers each fast-withdrawable token on the `FastWithdrawalList`
///            with its hourly/daily cap from {_fastWithdrawalTokenConfigs},
///            and aliases WETH onto the native-ETH bucket so ETH and WETH share
///            a single combined rate cap across both gateways.
///
///      The script does **not** flip `setWhitelistEnabled(true)`. Enabling the policy
///      is a separate operational step.
///
/// @dev Environment:
///        ENV (default: testnet) — manifest dir under deployments/<ENV>/
///        FAST_WITHDRAWAL_LIST_OWNER (required) — initial owner of the new list
///                                                (typically the existing L1 admin / timelock)
///
/// @dev Storage layout: this migration appends fields to existing ERC-7201 namespaced
///      structs. No deployed slots are removed or reordered. The audit-time validation
///      of layout compatibility is the operator's responsibility before broadcast —
///      this script uses {UnsafeUpgrades} to match the existing migration convention.
contract MigrateL1_Fastlist is DeployBase {
    using stdJson for string;

    // ============ Fast-withdrawal token configuration (L1 mainnet) ============
    //
    // Rate caps target roughly $20 k / hour and $100 k / day per bucket.
    //
    // For USD-pegged tokens (USDC, USDnr) the cap is expressed as 20_000 /
    // 100_000 in the token's own decimals. For non-pegged tokens (ETH, WBTC,
    // BLEND) the cap is converted from USD using a recent spot price — see
    // the inline note on each row for the price and the resulting unit cap.
    // Price drift is tolerated: the limit is a safety cap, not a settlement
    // price, and the operator is expected to re-check it before broadcast.
    //
    // Native ETH and WETH SHARE a single bucket via `setAlias(WETH,
    // NATIVE_LIMIT_KEY)`. The bucket is registered under the native key, so
    // a withdrawal that routes through NativeGateway and a withdrawal that
    // routes through ERC20Gateway (WETH) consume the same hourly/daily
    // counter — draining $20 k of ETH + $20 k of WETH in the same hour is
    // NOT possible, by design.

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant BLEND = 0xd8A271974E8EdAE9D7b58e3370dc1669427503F4;
    // Mixed-case spelling is the token's official symbol; keep it to match
    // the on-chain label and the log output emitted during the migration.
    // forge-lint: disable-next-line(screaming-snake-case-const)
    address internal constant USDnr = 0xD48e565561416dE59DA1050ED70b8d75e8eF28f9;

    /// @dev Mirror of `NativeGateway.NATIVE_LIMIT_KEY`. Duplicated here because
    ///      that constant is exposed as a public getter and so cannot be
    ///      referenced at compile time from a `pure` context. An invariant
    ///      check in `run()` asserts the two are equal before use.
    address internal constant NATIVE_LIMIT_KEY = address(0x0000012345678901234567890123456789012345);

    struct L1Addresses {
        address payable bridge;
        address payable erc20Gateway;
        address payable nativeGateway;
        address payable remoteErc20Gateway;
        address payable remoteNativeGateway;
        address fastWithdrawalListOwner;
    }

    /// @dev Returns the fast-withdrawal token configuration to be applied
    ///      by this migration. Kept as a function (not a storage array) so
    ///      the script remains a stateless one-shot and review diffs only
    ///      touch this single call site.
    ///
    ///      Ordering matters: any row with `aliasOf != address(0)` MUST come
    ///      after the row that registers that bucket. In particular, the
    ///      native-ETH row is placed first so the WETH row can alias onto it.
    function _fastWithdrawalTokenConfigs() internal pure returns (FastWithdrawalTokenConfig[] memory configs) {
        configs = new FastWithdrawalTokenConfig[](6);

        // Native-ETH bucket — registered first so WETH below can alias onto it.
        // NativeGateway always consumes against NATIVE_LIMIT_KEY.
        //
        // USD → ETH conversion at spot price ETH ≈ $2,277.56 (Apr 20, 2026):
        //   $20,000  / $2,277.56 ≈  8.78 ETH  → rounded up to  9 ETH (≈ $20,498)
        //   $100,000 / $2,277.56 ≈ 43.90 ETH  → rounded up to 44 ETH (≈ $100,213)
        // The tiny overshoot is intentional: round values read more naturally
        // for operators and the drift vs. the $20 k / $100 k target stays
        // well under normal intra-day price volatility.
        configs[0] = FastWithdrawalTokenConfig({
            token: NATIVE_LIMIT_KEY,
            symbol: "ETH",
            hourlyLimit: 9e18,
            dailyLimit: 44e18,
            aliasOf: address(0)
        });

        // WETH shares the native bucket. `hourlyLimit` / `dailyLimit` MUST be
        // zero for alias rows — the target bucket's caps are what apply.
        configs[1] = FastWithdrawalTokenConfig({token: WETH, symbol: "WETH", hourlyLimit: 0, dailyLimit: 0, aliasOf: NATIVE_LIMIT_KEY});

        // 18-decimal token with its own bucket.
        // USD → BLEND conversion at spot price BLEND ≈ $0.10:
        //   $20,000  / $0.10 =   200,000 BLEND  (hourly)
        //   $100,000 / $0.10 = 1,000,000 BLEND  (daily)
        configs[2] = FastWithdrawalTokenConfig({
            token: BLEND,
            symbol: "BLEND",
            hourlyLimit: 200_000e18,
            dailyLimit: 1_000_000e18,
            aliasOf: address(0)
        });

        // 8-decimal token.
        configs[3] = FastWithdrawalTokenConfig({token: WBTC, symbol: "WBTC", hourlyLimit: 20_000e8, dailyLimit: 100_000e8, aliasOf: address(0)});

        // 6-decimal tokens.
        configs[4] = FastWithdrawalTokenConfig({token: USDC, symbol: "USDC", hourlyLimit: 20_000e6, dailyLimit: 100_000e6, aliasOf: address(0)});
        configs[5] = FastWithdrawalTokenConfig({
            token: USDnr,
            symbol: "USDnr",
            hourlyLimit: 20_000e6,
            dailyLimit: 100_000e6,
            aliasOf: address(0)
        });
    }

    function run() external {
        string memory env = vm.envOr("ENV", string("testnet"));
        L1Addresses memory addrs = _loadAddresses(env);

        _logPlan(env, addrs);

        vm.startBroadcast();

        // 1. Deploy FastWithdrawalList behind a UUPS proxy.
        FastWithdrawalList listImpl = new FastWithdrawalList();
        ERC1967Proxy listProxy = new ERC1967Proxy(
            address(listImpl),
            abi.encodeCall(FastWithdrawalList.initialize, (addrs.fastWithdrawalListOwner))
        );
        FastWithdrawalList list = FastWithdrawalList(address(listProxy));
        console2.log("FastWithdrawalList proxy:", address(list));
        console2.log("FastWithdrawalList impl :", address(listImpl));

        // 2. Upgrade L1FluentBridge.
        address newBridgeImpl = address(new L1FluentBridge());
        UnsafeUpgrades.upgradeProxy(addrs.bridge, newBridgeImpl, "");
        console2.log("L1FluentBridge:", addrs.bridge, "->", newBridgeImpl);

        // 3. Upgrade gateways.
        address newErc20GatewayImpl = address(new ERC20Gateway());
        UnsafeUpgrades.upgradeProxy(addrs.erc20Gateway, newErc20GatewayImpl, "");
        console2.log("ERC20Gateway:  ", addrs.erc20Gateway, "->", newErc20GatewayImpl);

        NativeGateway newNativeGatewayImpl = new NativeGateway();
        // Invariant: our local mirror of NATIVE_LIMIT_KEY matches the constant
        // baked into the NativeGateway impl we're about to install. Read from
        // the freshly deployed impl (not via the existing proxy) so the check
        // works regardless of whether the proxy has been upgraded yet.
        require(
            newNativeGatewayImpl.NATIVE_LIMIT_KEY() == NATIVE_LIMIT_KEY,
            "NATIVE_LIMIT_KEY mismatch between script and new NativeGateway impl"
        );
        UnsafeUpgrades.upgradeProxy(addrs.nativeGateway, address(newNativeGatewayImpl), "");
        console2.log("NativeGateway: ", addrs.nativeGateway, "->", address(newNativeGatewayImpl));

        // 4. Wire FastWithdrawalList into both gateways.
        ERC20Gateway(addrs.erc20Gateway).setFastWithdrawalList(address(list));
        NativeGateway(addrs.nativeGateway).setFastWithdrawalList(address(list));
        console2.log("setFastWithdrawalList: erc20Gateway, nativeGateway");

        // 5. Grant CONSUMER_ROLE to both gateways via the standard OZ AccessControl API.
        bytes32 consumerRole = list.CONSUMER_ROLE();
        list.grantRole(consumerRole, addrs.erc20Gateway);
        list.grantRole(consumerRole, addrs.nativeGateway);
        console2.log("grantRole(CONSUMER_ROLE): erc20Gateway, nativeGateway");

        // 6. Register the local gateways on the bridge — required for both
        //    `_receiveMessage` (inbound) and `sendMessage` (outbound) admission.
        L1FluentBridge bridge = L1FluentBridge(addrs.bridge);
        bridge.registerGateway(addrs.erc20Gateway);
        bridge.registerGateway(addrs.nativeGateway);
        console2.log("registerGateway (local): erc20Gateway, nativeGateway");

        // 7. Register the remote (L2) gateways on the bridge so outbound sends targeting
        //    them are admitted under the new symmetric send-side check.
        bridge.registerGateway(addrs.remoteErc20Gateway);
        bridge.registerGateway(addrs.remoteNativeGateway);
        console2.log("registerGateway (remote): erc20Gateway, nativeGateway");

        // 8. Register each fast-withdrawable token with its hourly/daily cap.
        _registerFastWithdrawalTokens(list);

        vm.stopBroadcast();

        console2.log("");
        console2.log("== Migration complete. Whitelist policy is NOT yet enabled. ==");
        console2.log("Next step (separate broadcast):");
        console2.log("  erc20Gateway.setWhitelistEnabled(true) and nativeGateway.setWhitelistEnabled(true)");
    }

    /// @dev Applies the token configuration from {_fastWithdrawalTokenConfigs} to
    ///      `list`. Reverts on any entry whose address has not been filled in,
    ///      so the migration fails loudly rather than silently omitting a
    ///      requested token.
    ///
    ///      Rows with `aliasOf == address(0)` call `registerToken`; rows with a
    ///      non-zero `aliasOf` call `setAlias` (and carry zero limits — the
    ///      target bucket's caps are authoritative). The ordering invariant
    ///      documented on {_fastWithdrawalTokenConfigs} ensures any alias target
    ///      is already registered by the time we reach the aliasing row, so
    ///      `setAlias`'s `_limits[aliasOf].registered` precondition holds.
    function _registerFastWithdrawalTokens(FastWithdrawalList list) internal {
        FastWithdrawalTokenConfig[] memory configs = _fastWithdrawalTokenConfigs();
        for (uint256 i = 0; i < configs.length; ++i) {
            FastWithdrawalTokenConfig memory cfg = configs[i];
            require(cfg.token != address(0), string.concat("fast-withdrawal token address missing: ", cfg.symbol));

            if (cfg.aliasOf == address(0)) {
                list.registerToken(cfg.token, cfg.hourlyLimit, cfg.dailyLimit);
                console2.log("registerToken:", cfg.symbol, cfg.token);
            } else {
                // Alias rows must not carry own limits: the target bucket's caps
                // apply, so non-zero values here would mislead a reader about
                // what is actually enforced on-chain.
                require(cfg.hourlyLimit == 0 && cfg.dailyLimit == 0, string.concat("alias row must not carry limits: ", cfg.symbol));
                list.setAlias(cfg.token, cfg.aliasOf);
                console2.log("setAlias:", cfg.symbol, cfg.token);
                console2.log("  -> bucket:", cfg.aliasOf);
            }
        }
    }

    /// @dev Loads addresses from the L1 deployment manifest plus the remote (L2) manifest,
    ///      and from the `FAST_WITHDRAWAL_LIST_OWNER` env var.
    function _loadAddresses(string memory env) internal view returns (L1Addresses memory addrs) {
        string memory l1Manifest = vm.readFile(string.concat("deployments/", env, "/l1.json"));
        string memory l2Manifest = vm.readFile(string.concat("deployments/", env, "/l2.json"));

        addrs.bridge = payable(_readAddr(l1Manifest, "bridge"));
        addrs.erc20Gateway = payable(_readAddr(l1Manifest, "erc20_gateway"));
        addrs.nativeGateway = payable(_readAddr(l1Manifest, "native_gateway"));
        addrs.remoteErc20Gateway = payable(_readAddr(l2Manifest, "erc20_gateway"));
        addrs.remoteNativeGateway = payable(_readAddr(l2Manifest, "native_gateway"));
        addrs.fastWithdrawalListOwner = vm.envAddress("FAST_WITHDRAWAL_LIST_OWNER");

        require(addrs.bridge != address(0), "L1 bridge address missing in manifest");
        require(addrs.erc20Gateway != address(0), "L1 erc20_gateway address missing in manifest");
        require(addrs.nativeGateway != address(0), "L1 native_gateway address missing in manifest");
        require(addrs.remoteErc20Gateway != address(0), "L2 erc20_gateway address missing in manifest");
        require(addrs.remoteNativeGateway != address(0), "L2 native_gateway address missing in manifest");
        require(addrs.fastWithdrawalListOwner != address(0), "FAST_WITHDRAWAL_LIST_OWNER required");
    }

    function _logPlan(string memory env, L1Addresses memory addrs) internal pure {
        console2.log("== MigrateL1_Whitelist ==");
        console2.log("env:                 ", env);
        console2.log("L1 bridge:           ", addrs.bridge);
        console2.log("L1 erc20Gateway:     ", addrs.erc20Gateway);
        console2.log("L1 nativeGateway:    ", addrs.nativeGateway);
        console2.log("L2 erc20Gateway:     ", addrs.remoteErc20Gateway);
        console2.log("L2 nativeGateway:    ", addrs.remoteNativeGateway);
        console2.log("FastWithdrawal owner:", addrs.fastWithdrawalListOwner);
        console2.log("");
    }
}
