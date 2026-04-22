// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {GatewayBase} from "./GatewayBase.sol";
import {FluentBridge} from "../bridge/FluentBridge.sol";

import {IWETH} from "../interfaces/IWETH.sol";
import {IWETHGateway} from "../interfaces/gateways/IWETHGateway.sol";

/**
 * @title WETHGateway
 * @author Fluent Labs
 *
 * @notice Gateway that bridges canonical WETH between chains by unwrapping into native
 *         ETH on the source side, transporting ETH through {FluentBridge}, and re-
 *         wrapping into the canonical WETH on the destination. From the user's
 *         perspective the flow is always WETH in → WETH out.
 *
 * @dev Dual-chain use:
 *      The same implementation runs on both sides of the bridge:
 *        - L1: `_weth` points at the canonical WETH9 contract.
 *        - L2: `_weth` points at the Universal-token WETH (precompile-backed).
 *      Once the Fluent L2 precompile upgrade exposes `deposit()` / `withdraw(uint256)`
 *      with standard WETH9 semantics, both targets satisfy {IWETH} and the gateway's
 *      wrap/unwrap logic is chain-agnostic.
 *
 * @dev L2 bootstrap (Universal-token WETH):
 *      1. Deploy this contract behind a UUPS proxy on L2.
 *      2. As the {UniversalTokenFactory} owner (owner-bypass of `onlyPaymentGateway`),
 *         call `factory.deployToken(<this>, L1_WETH, abi.encode("Wrapped Ether", "WETH",
 *         18, 0, address(0), <this>, true))`. The outer `minter` field must be `address(0)`
 *         (factory requirement when `wrapped == true`); `pauser` is typically `<this>` for
 *         emergency controls. Normal user flow uses `deposit`/`withdraw` only.
 *      3. `setWETH(<universal-weth address>)` on the gateway.
 *      4. Pair both gateways via `setOtherSideGateway` and register both on their
 *         respective bridges.
 *
 *      Step (1) may use `initialize(..., wethContract = address(0))` so the proxy
 *      address is known before the CREATE2 Universal-WETH deploy; all send/receive
 *      paths revert with {WETHNotConfigured} until {setWETH} completes step (3).
 *
 * @dev This contract is a peer of {NativeGateway}: it uses `FluentBridge.sendMessage`
 *      directly and carries value as native ETH across the wire. The only difference
 *      is that WETH is pulled from / pushed to the user at the edges. This keeps all
 *      bridge-protocol mechanics — message framing, preconfirmation gating, fast-
 *      withdrawal caps, failed-message retries — identical to the native path.
 *
 * @dev Rate-limit key:
 *      The receive leg debits {NativeGateway.NATIVE_LIMIT_KEY}. That means any
 *      `FastWithdrawalList` cap registered against the native-ETH sentinel is shared
 *      atomically by ETH withdrawals (via {NativeGateway}) AND WETH withdrawals (via
 *      this gateway on either chain). An attacker cannot drain `cap` ETH + `cap` WETH
 *      in the same window by racing the gateways — they all consume the same counter.
 *
 * @dev Pegged-WETH collision:
 *      The operator should set {ERC20Gateway.setBridgingExcludedOrigin}(L1_WETH, true) on both
 *      chains so the generic gateway rejects that origin.
 *      Without it, users could still bridge L1 WETH through `ERC20Gateway` and mint a second
 *      pegged representation whose address diverges from the Universal-WETH this gateway targets.
 */
contract WETHGateway is GatewayBase, IWETHGateway {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /**
     * @dev Shared fast-withdrawal bucket key. Duplicated from {NativeGateway} by value
     *      so this gateway doesn't need a runtime reference to the native gateway —
     *      keeps upgradeability simple and avoids coupling deployment order.
     *
     *      MUST stay byte-identical to `NativeGateway.NATIVE_LIMIT_KEY`. A mismatch
     *      would split the bucket and defeat the whole point of sharing the cap.
     */
    address public constant NATIVE_LIMIT_KEY = address(0x0000012345678901234567890123456789012345);

    /// @dev keccak256(abi.encode(uint256(keccak256("Fluent.storage.WETHGatewayStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WETH_GATEWAY_STORAGE_LOCATION = 0x975ef981a81c90b8ff091435d8c70db7525deba7cf93ec5fb11c7931febbe600;

    /// @custom:storage-location erc7201:Fluent.storage.WETHGatewayStorage
    struct WETHGatewayStorage {
        /// @dev Canonical WETH contract on this chain that `deposit`/`withdraw` is called against.
        address _weth;
        /// @dev Reserved for future storage fields.
        uint256[50] __gap;
    }

    /// @dev Returns the ERC-7201 storage pointer for WETH gateway state.
    function _getWETHGatewayStorage() private pure returns (WETHGatewayStorage storage $) {
        assembly ("memory-safe") {
            $.slot := WETH_GATEWAY_STORAGE_LOCATION
        }
    }

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Lock the implementation so only proxies can initialize it.
        _disableInitializers();
    }

    /**
     * @notice Initializes the WETH gateway (replaces constructor when used behind a proxy).
     * @param initialOwner Owner address for admin functions (two-step).
     * @param bridgeContract Local {FluentBridge} address for cross-chain message dispatch.
     * @param wethContract Canonical WETH address on this chain, or `address(0)` to defer
     *        wiring until {setWETH} (required for L2 Universal-token bootstrap where the
     *        gateway address participates in the CREATE2 salt).
     */
    function initialize(address initialOwner, address bridgeContract, address wethContract) external initializer {
        __GatewayBase_init(initialOwner, bridgeContract);
        if (wethContract != address(0)) {
            _setWETH(wethContract);
        }
    }

    // ============ Send WETH ============

    /// @inheritdoc IWETHGateway
    function sendWETH(address to, uint256 amount) external payable nonReentrant {
        address sender = msg.sender;

        // Remote gateway must be configured — without it, `sendMessage` has no destination.
        require(getOtherSideGateway() != address(0), ZeroAddressNotAllowed("getOtherSideGateway"));
        require(to != address(0), InvalidRecipient());
        // Reject no-op bridging that would still consume a relay fee.
        require(amount > 0, ZeroValueNotAllowed("amount"));

        // Exact fee, like {ERC20Gateway.sendTokens}. Excess ETH in the outbound value would
        // land on the remote bridge but the WETH receive function expects exactly `amount`,
        // so a mismatch would permanently fail delivery.
        uint256 fee = FluentBridge(getBridgeContract()).getSentMessageFee();
        require(msg.value == fee, ExactFeeRequired());

        _requireAccountNotBlacklisted(sender);
        if (sender != to) {
            _requireAccountNotBlacklisted(to);
        }

        address weth = getWETH();
        require(weth != address(0), WETHNotConfigured());

        // Pull WETH, then unwrap. Balance-delta around `withdraw` defends against a
        // non-canonical or buggy WETH implementation that returns the wrong amount of
        // native value — we would catch that before forwarding ETH to the bridge.
        IERC20(weth).safeTransferFrom(sender, address(this), amount);

        uint256 nativeBefore = address(this).balance;
        IWETH(weth).withdraw(amount);
        uint256 nativeGained = address(this).balance - nativeBefore;
        require(nativeGained == amount, UnwrapAccountingMismatch());

        // Forward the full `amount + fee` so the bridge receives the native value to
        // transport and retains the fee portion for relayer reimbursement.
        FluentBridge(getBridgeContract()).sendMessage{value: amount + fee}(
            getOtherSideGateway(),
            abi.encodeCall(IWETHGateway.receiveWETH, (sender, to, amount))
        );
    }

    // ============ Receive WETH ============

    /// @inheritdoc IWETHGateway
    function receiveWETH(address from, address to, uint256 amount) external payable onlyFluentBridge nonReentrant {
        // Trust check: the original cross-chain sender must be the configured peer gateway.
        // Without this, any contract that can call the remote bridge could mint WETH here.
        require(FluentBridge(msg.sender).getNativeSender() == getOtherSideGateway(), MessageFromWrongGateway());
        require(msg.value == amount, InvalidNativeAmount());
        require(to != address(0), InvalidRecipient());

        address weth = getWETH();
        require(weth != address(0), WETHNotConfigured());

        // Share the native-ETH bucket: ETH and WETH withdrawals are rate-limited together.
        // No-op while whitelist is disabled; reverts on Preconfirmed-batch receive if the
        // native key is not registered in `FastWithdrawalList`.
        _consumeLimit(NATIVE_LIMIT_KEY, amount);

        // Wrap ETH → WETH, then forward. Balance-delta around `deposit` symmetrically
        // defends against a buggy WETH that does not mint 1:1.
        uint256 wethBefore = IERC20(weth).balanceOf(address(this));
        IWETH(weth).deposit{value: amount}();
        uint256 wethGained = IERC20(weth).balanceOf(address(this)) - wethBefore;
        require(wethGained == amount, WrapAccountingMismatch());

        uint256 recipientBefore = IERC20(weth).balanceOf(to);
        IERC20(weth).safeTransfer(to, amount);
        uint256 recipientGained = IERC20(weth).balanceOf(to) - recipientBefore;
        require(recipientGained == amount, TransferAccountingMismatch());

        emit ReceivedTokens(from, to, amount);
    }

    // ============ Admin / Rescue ============

    /// @dev Validates and stores the WETH address. Reverts on zero address.
    function _setWETH(address newWETH) internal {
        require(newWETH != address(0), ZeroAddressNotAllowed("weth"));
        WETHGatewayStorage storage $ = _getWETHGatewayStorage();
        emit WETHUpdated($._weth, newWETH);
        $._weth = newWETH;
    }

    // ============ Views ============

    /// @inheritdoc IWETHGateway
    function getWETH() public view returns (address) {
        return _getWETHGatewayStorage()._weth;
    }

    /// @dev Accepts bare ETH — required on the receive path (WETH.withdraw refunds value to us)
    ///      and for failed-message retries that re-deliver ETH into the gateway before wrapping.
    receive() external payable {}
}
