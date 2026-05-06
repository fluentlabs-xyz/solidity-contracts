 // // SPDX-License-Identifier: Apache-2.0
// pragma solidity 0.8.30;

// import {Script} from "forge-std/Script.sol";
// import {console2} from "forge-std/console2.sol";

// import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// import {UniversalTokenFactory} from "../../../contracts/factories/UniversalTokenFactory.sol";
// import {WETHGateway} from "../../../contracts/gateways/WETHGateway.sol";
// import {IWETHGateway} from "../../../contracts/interfaces/gateways/IWETHGateway.sol";

// /// @title MockFluentBridge (test shim)
// /// @notice Minimal bridge double that lets an EOA drive {WETHGateway} end-to-end against
// ///         the real Fluent-dev Universal-token precompile, without deploying
// ///         {FluentBridge}. Implements only the surface the gateway actually calls:
// ///
// ///           - `onlyFluentBridge`               → `msg.sender == this` (we are "the bridge")
// ///           - `getNativeSender()`              → consumed by {WETHGateway.receiveWETH} to
// ///                                                verify the remote-peer identity
// ///           - `getSentMessageFee()`            → 0 (free bridging in this harness)
// ///           - `sendMessage(target, data)` payable → accepts and retains the native value
// ///                                                   forwarded by `sendWETH`
// ///           - `isCurrentBatchPreconfirmed()`  → `false` (no batch context in harness)
// ///
// /// @dev Entrypoints:
// ///      - {triggerReceiveWETH} calls {WETHGateway.receiveWETH} with the configured
// ///        native sender and the EOA-supplied ETH as `msg.value`.
// ///
// /// @dev Not for production. All state here is owner-writable and unpaused.
// contract MockFluentBridge {
//     address public nativeSender;

//     /// @notice Set by {triggerReceiveWETH} before delegating into the gateway.
//     function setNativeSender(address sender) external {
//         nativeSender = sender;
//     }

//     /// @notice Consumed by {WETHGateway.receiveWETH}: must equal
//     ///         `getOtherSideGateway()` configured on the gateway.
//     function getNativeSender() external view returns (address) {
//         return nativeSender;
//     }

//     /// @notice Bridge fee charged by {FluentBridge.sendMessage}. Zero for the harness
//     ///         so `sendWETH` only needs to supply `amount` of native value.
//     function getSentMessageFee() external pure returns (uint256) {
//         return 0;
//     }

//     /// @notice Read surface consulted by {GatewayBase._consumeLimit}. Only relevant
//     ///         when `whitelistEnabled` is true — we never enable it here.
//     function isCurrentBatchPreconfirmed() external pure returns (bool) {
//         return false;
//     }

//     /// @notice {WETHGateway.sendWETH} forwards `amount + fee` into this via
//     ///         `sendMessage{value: amount + fee}`; we simply retain it so the EOA
//     ///         can later verify that the gateway unwrapped and forwarded the full
//     ///         native value.
//     function sendMessage(address target, bytes calldata data) external payable {
//         // Silence unused-variable warnings; retained for event introspection if needed.
//         target;
//         data;
//     }

//     /// @notice Drives the receive leg: sets the native sender, then calls the gateway's
//     ///         `receiveWETH` with the EOA-supplied native value.
//     function triggerReceiveWETH(address payable gateway, address nativeSender_, address from, address to, uint256 amount) external payable {
//         require(msg.value == amount, "MockFluentBridge: value != amount");
//         nativeSender = nativeSender_;
//         IWETHGateway(gateway).receiveWETH{value: amount}(from, to, amount);
//     }

//     /// @dev Accept bare ETH (unused in-band, handy for top-ups).
//     receive() external payable {}
// }

// /// @title TestFluentDevPrecompile
// /// @author Fluent Labs
// ///
// /// @notice End-to-end harness for the Universal-token precompile on **Fluent devnet**
// ///         (`FLUENT_DEV_RPC_URL`). Deploys a fresh {UniversalTokenFactory}, then:
// ///
// ///         - A **non-wrapped** pegged token (six `deployArgs` fields, matching {ERC20Gateway}),
// ///         - A **wrapped** Universal-WETH (seven `deployArgs` fields ending in `true`),
// ///           plus {WETHGateway} and {MockFluentBridge} to exercise `deposit` / `withdraw`.
// ///
// /// @dev Flow (single broadcast):
// ///      1. Deploy {UniversalTokenFactory} behind an ERC1967 proxy.
// ///      2. Deploy non-wrapped pegged token: `deployToken(deployer, originPlain, abi.encode(...6))`;
// ///         assert ERC20 metadata via {IERC20Metadata}.
// ///      3. Deploy {MockFluentBridge} shim.
// ///      4. Deploy {WETHGateway} proxy (`weth` deferred, `bridgeContract = shim`).
// ///      5. Deploy wrapped Universal-WETH: `deployToken(gateway, originWeth, abi.encode(..., true))`.
// ///      6. Wire gateway WETH + `otherSideGateway = shim`.
// ///      7–9. `receiveWETH` / `sendWETH` round-trip on wrapped token (native ↔ WETH).
// ///
// /// @dev Run on Fluent devnet (load `.env` first so `FLUENT_DEV_RPC_URL` is set):
// ///        source .env && forge script scripts/migrations/testnet/TestFluentDevPrecompile.s.sol:TestFluentDevPrecompile \
// ///          --rpc-url "$FLUENT_DEV_RPC_URL" --broadcast --private-key "$PRIVATE_KEY" -vvv
// ///
// ///      Env (all optional):
// ///        - TEST_AMOUNT_WEI     default 0.01 ether (wrapped leg; must be <= deployer balance)
// ///        - ORIGIN_TOKEN        CREATE2 salt for wrapped token (default: keccak label)
// ///        - ORIGIN_TOKEN_PLAIN  CREATE2 salt for non-wrapped token (default: distinct keccak)
// ///        - RUN_WETH_ROUNDTRIP  "true" to exercise deposit/withdraw (WETH9 surface on the L2
// ///                              precompile). Default `false`: skip the round-trip since the
// ///                              `deposit()` / `withdraw(uint256)` surface is not yet live on
// ///                              Fluent devnet/testnet (`InvalidOperandOOG` inside the precompile).
// ///                              The wrapped token is still deployed + metadata-verified regardless.
// contract TestFluentDevPrecompile is Script {
//     // ============ Config ============

//     /// @dev Default test amount: 0.01 ether. Kept small so a lightly-funded dev EOA
//     ///      can complete the round trip without top-ups.
//     uint256 internal constant DEFAULT_AMOUNT = 0.01 ether;

//     // ============ Entrypoint ============

//     function run() external {
//         uint256 amount = vm.envOr("TEST_AMOUNT_WEI", DEFAULT_AMOUNT);
//         address originWeth = vm.envOr("ORIGIN_TOKEN", address(uint160(uint256(keccak256("fluent-dev-precompile-test-origin")))));
//         address originPlain = vm.envOr("ORIGIN_TOKEN_PLAIN", address(uint160(uint256(keccak256("fluent-dev-plain-pegged-origin")))));
//         bool runRoundTrip = vm.envOr("RUN_WETH_ROUNDTRIP", false);

//         // `tx.origin` under `forge script --private-key` is the signer's wallet
//         // address. We resolve it inside the broadcast so the same script works with
//         // `--private-key`, `--account`, or `--keystore` — and so we don't need the
//         // env `PRIVATE_KEY` to carry a `0x` prefix (devnet `.env` stores it raw).
//         vm.startBroadcast();
//         address deployer = tx.origin;

//         console2.log("== Fluent L2: Universal precompile (plain + wrapped) ==");
//         console2.log("chainId              :", block.chainid);
//         console2.log("deployer (EOA)       :", deployer);
//         console2.log("origin (wrapped WETH):", originWeth);
//         console2.log("origin (plain pegged):", originPlain);
//         console2.log("run WETH round-trip  :", runRoundTrip);
//         console2.log("amount (wei, WETH RT):", amount);

//         // Step 1 — Deploy UniversalTokenFactory (UUPS proxy, deployer is owner).
//         address factory = _deployUniversalFactory(deployer);
//         console2.log("UniversalTokenFactory:", factory);

//         // Step 2 — Non-wrapped pegged token (six deployArgs). `gateway` in CREATE2 salt is
//         //          the deployer here — only the salt identity; production uses {ERC20Gateway}.
//         bytes memory plainDeployArgs = abi.encode("Fluent Dev Peg", "FDPEG", uint8(18), uint256(0), deployer, deployer, false);
//         address plainPegged = UniversalTokenFactory(factory).deployToken(deployer, originPlain, plainDeployArgs);
//         console2.log("Universal plain PEG  :", plainPegged);
//         require(keccak256(bytes(IERC20Metadata(plainPegged).name())) == keccak256("Fluent Dev Peg"), "plain: name mismatch");
//         require(keccak256(bytes(IERC20Metadata(plainPegged).symbol())) == keccak256("FDPEG"), "plain: symbol mismatch");
//         require(IERC20Metadata(plainPegged).decimals() == 18, "plain: decimals mismatch");
//         console2.log("plain token metadata : OK");

//         // Step 3 — Deploy the bridge shim. The gateway treats this as both the
//         //          bridge contract AND (via `nativeSender`) the remote-peer gateway,
//         //          so all of receiveWETH's trust checks land on a single known address.
//         MockFluentBridge shim = new MockFluentBridge();
//         console2.log("MockFluentBridge     :", address(shim));

//         // Step 4 — Deploy WETHGateway proxy. WETH deferred; bridge = shim.
//         //          We also pin `otherSideGateway = shim` so `nativeSender` can just be
//         //          the shim itself (see Step 6).
//         WETHGateway gateway = _deployWETHGateway(deployer, address(shim));
//         console2.log("WETHGateway          :", address(gateway));

//         // Step 5 — Deploy the Universal-token pegged WETH with `wrapped = true`
//         //          so the L2 precompile exposes WETH9 `deposit` / `withdraw`.
//         //          minter = pauser = gateway (emergency surface only; production flow
//         //          uses deposit/withdraw exclusively).
//         bytes memory wethDeployArgs = abi.encode("Wrapped Ether", "WETH", uint8(18), uint256(0), address(0), address(gateway), true);
//         address universalWeth = UniversalTokenFactory(factory).deployToken(address(gateway), originWeth, wethDeployArgs);
//         console2.log("Universal-WETH       :", universalWeth);

//         // Step 6 — Finish wiring: point gateway at Universal-WETH, set the "other side"
//         //          to the shim, matching what `getNativeSender` will return on receive.
//         gateway.setWETH(universalWeth);
//         gateway.setOtherSideGateway(address(shim));

//         // Steps 7–10 exercise the WETH9 `deposit` / `withdraw` surface on the precompile.
//         // Gated behind `RUN_WETH_ROUNDTRIP` because that surface is not yet live on Fluent
//         // devnet/testnet (precompile reverts with `InvalidOperandOOG` on `deposit()`).
//         // Deploy of both tokens above is always performed so layouts can still be validated.
//         if (runRoundTrip) {
//             _runWethRoundTrip(gateway, shim, universalWeth, deployer, amount);
//         } else {
//             console2.log("-- WETH round-trip SKIPPED (RUN_WETH_ROUNDTRIP != true) --");
//         }

//         vm.stopBroadcast();

//         if (runRoundTrip) {
//             console2.log("== Round-trip OK (wrapped); plain pegged deployed & metadata OK ==");
//         } else {
//             console2.log("== Deploys OK (plain pegged + wrapped Universal-WETH); round-trip skipped ==");
//         }
//         console2.log("export TEST_FACTORY=", factory);
//         console2.log("export TEST_PLAIN_PEGGED=", plainPegged);
//         console2.log("export TEST_GATEWAY=", address(gateway));
//         console2.log("export TEST_UNIVERSAL_WETH=", universalWeth);
//         console2.log("export TEST_MOCK_BRIDGE=", address(shim));
//     }

//     // ============ Deploy helpers ============

//     /// @dev Bare ERC1967 proxy deploy — bypasses the OZ upgrades plugin's storage-layout
//     ///      validation, which would need a reference build for the modified factory impl.
//     function _deployUniversalFactory(address initialOwner) internal returns (address) {
//         UniversalTokenFactory impl = new UniversalTokenFactory();
//         ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(UniversalTokenFactory.initialize, (initialOwner)));
//         return address(proxy);
//     }

//     /// @dev Same two-phase bootstrap as {ReleaseWethMigration.deployL2} (L2 WETH + Universal token)
//     ///      but collapsed for the single-broadcast test harness: WETH is wired post-deploy.
//     function _deployWETHGateway(address initialOwner, address bridgeContract) internal returns (WETHGateway) {
//         WETHGateway impl = new WETHGateway();
//         ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(WETHGateway.initialize, (initialOwner, bridgeContract, address(0))));
//         return WETHGateway(payable(address(proxy)));
//     }

//     /// @dev `receiveWETH` (precompile `deposit`) + `sendWETH` (precompile `withdraw`) round trip.
//     ///      Extracted so `run()` stays readable and the round trip is easy to gate behind
//     ///      `RUN_WETH_ROUNDTRIP` while deploy smoke tests continue to run unconditionally.
//     function _runWethRoundTrip(WETHGateway gateway, MockFluentBridge shim, address universalWeth, address deployer, uint256 amount) internal {
//         require(deployer.balance >= amount, "deployer balance < TEST_AMOUNT_WEI");

//         uint256 gatewayBalBefore = address(gateway).balance;
//         uint256 shimBalBefore = address(shim).balance;
//         uint256 recipientWethBefore = IERC20(universalWeth).balanceOf(deployer);

//         // Step 7 — Simulate the bridge inbound: gateway will call `universalWeth.deposit{value:amount}()`.
//         shim.triggerReceiveWETH{value: amount}(payable(address(gateway)), address(shim), deployer, deployer, amount);

//         uint256 recipientWethAfterReceive = IERC20(universalWeth).balanceOf(deployer);
//         console2.log("-- after receiveWETH --");
//         console2.log("EOA Universal-WETH   :", recipientWethAfterReceive);
//         console2.log("gateway native bal   :", address(gateway).balance);
//         console2.log("gateway WETH bal     :", IERC20(universalWeth).balanceOf(address(gateway)));
//         console2.log("shim native delta    :", int256(address(shim).balance) - int256(shimBalBefore));

//         // Step 8 — Invariants for the deposit leg.
//         require(recipientWethAfterReceive - recipientWethBefore == amount, "receiveWETH: recipient did not receive exact amount");
//         require(address(gateway).balance == gatewayBalBefore, "receiveWETH: gateway retained native");
//         require(IERC20(universalWeth).balanceOf(address(gateway)) == 0, "receiveWETH: gateway retained WETH");

//         // Step 9 — Send back: gateway calls `universalWeth.withdraw(amount)` → native ETH → shim.
//         IERC20(universalWeth).approve(address(gateway), amount);
//         uint256 shimBalPreSend = address(shim).balance;
//         gateway.sendWETH(deployer, amount);

//         uint256 recipientWethAfterSend = IERC20(universalWeth).balanceOf(deployer);
//         uint256 shimNativeGained = address(shim).balance - shimBalPreSend;

//         console2.log("-- after sendWETH --");
//         console2.log("EOA Universal-WETH   :", recipientWethAfterSend);
//         console2.log("gateway native bal   :", address(gateway).balance);
//         console2.log("gateway WETH bal     :", IERC20(universalWeth).balanceOf(address(gateway)));
//         console2.log("shim native gained   :", shimNativeGained);

//         // Step 10 — Invariants for the withdraw leg.
//         require(recipientWethAfterReceive - recipientWethAfterSend == amount, "sendWETH: EOA balance did not decrease by exact amount");
//         require(shimNativeGained == amount, "sendWETH: shim did not receive exact native amount");
//         require(address(gateway).balance == gatewayBalBefore, "sendWETH: gateway retained native");
//         require(IERC20(universalWeth).balanceOf(address(gateway)) == 0, "sendWETH: gateway retained WETH");
//     }
// }
