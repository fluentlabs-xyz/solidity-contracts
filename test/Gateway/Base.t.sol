// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IFluentBridge, IFluentBridgeRead} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {L1BlockOracle} from "../../contracts/oracles/L1BlockOracle.sol";
import {L1GasOracle} from "../../contracts/oracles/L1GasOracle.sol";
import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {MockERC20Token} from "../mocks/MockERC20.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {FastWithdrawalList} from "../../contracts/fastlist/FastWithdrawalList.sol";
import {IFastWithdrawalList} from "../../contracts/interfaces/IFastWithdrawalList.sol";

abstract contract GatewayBase is Test {
    address internal admin = makeAddr("admin");
    address internal relayer = makeAddr("relayer");
    address internal user = makeAddr("user");
    address internal recipient = makeAddr("recipient");
    address internal remoteBridge = makeAddr("remoteBridge");
    address internal remoteGateway = makeAddr("remoteGateway");

    uint256 internal sourceChainId;
    /// @dev Starts at 2 so the first test-relayed message has a `validUntilBlockNumber` strictly
    ///      greater than the default L1 block oracle value (1). Tests that exercise the
    ///      past-deadline branch advance the oracle past this value instead of shrinking it.
    uint256 internal nextSourceBlock = 2;

    IFluentBridge internal bridge;
    L1BlockOracle internal oracle;
    ERC20TokenFactory internal factory;
    ERC20Gateway internal gateway;
    ERC20PeggedToken internal peggedImplementation;
    MockERC20Token internal originToken;
    FastWithdrawalList internal fastWithdrawalList;

    function setUp() public virtual {
        sourceChainId = block.chainid + 1;
    }

    function _deployBridge(uint256 /* receiveMessageDeadline */) internal {
        oracle = new L1BlockOracle(admin);
        vm.prank(admin);
        oracle.updateL1BlockNumber(1);
        L1GasOracle gasOracle = new L1GasOracle(relayer);

        L2FluentBridge impl = new L2FluentBridge();
        IFluentBridge.InitConfiguration memory params = IFluentBridge.InitConfiguration({
            adminRole: admin,
            pauserRole: admin,
            relayerRole: relayer,
            otherBridge: remoteBridge
        });

        // Gateway tests rely on the trusted relayer path (receiveMessage),
        // which exists on L2 bridge. The receive-message deadline is now L1-owned and
        // committed per-message as validUntilBlockNumber, so L2 init no longer takes it.
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                L2FluentBridge.initialize,
                (abi.encode(params), address(oracle), address(gasOracle), 0, 0, 0, makeAddr("feeTreasury"))
            )
        );
        bridge = IFluentBridge(payable(address(proxy)));
        vm.prank(admin);
        (bool ok, ) = address(bridge).call(abi.encodeWithSignature("setExecuteGasLimit(uint256)", 2_000_000));
        assertTrue(ok, "setExecuteGasLimit failed");
    }

    /// @dev Register an arbitrary gateway on the bridge. The bridge rejects both
    ///      `sendMessage` and `_receiveMessage` whose peer isn't registered; test helpers
    ///      call this before delivering so legitimate receivers aren't rejected mid-flow.
    ///      Idempotent — the admin setter has no "already registered" check.
    function _registerGateway(address target) internal {
        vm.prank(admin);
        (bool ok, ) = address(bridge).call(abi.encodeWithSignature("registerGateway(address)", target));
        require(ok, "registerGateway failed");
    }

    /// @dev Deploys the shared {FastWithdrawalList} behind a UUPS proxy. Reused by both the
    ///      ERC20 and native gateway test paths so each can wire its own gateway as a
    ///      consumer. Idempotent against multiple calls within the same test (the second
    ///      deploy just overwrites `fastWithdrawalList` — fine for tests).
    function _deployFastWithdrawalList() internal {
        FastWithdrawalList listImpl = new FastWithdrawalList();
        ERC1967Proxy listProxy = new ERC1967Proxy(address(listImpl), abi.encodeCall(FastWithdrawalList.initialize, (admin)));
        fastWithdrawalList = FastWithdrawalList(address(listProxy));
    }

    function _deployGatewayStack() internal {
        peggedImplementation = new ERC20PeggedToken();

        ERC20TokenFactory factoryImpl = new ERC20TokenFactory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(ERC20TokenFactory.initialize, (admin, address(peggedImplementation)))
        );
        factory = ERC20TokenFactory(address(factoryProxy));

        ERC20Gateway gatewayImpl = new ERC20Gateway();
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(
            address(gatewayImpl),
            abi.encodeCall(ERC20Gateway.initialize, (admin, address(bridge), address(factory)))
        );
        gateway = ERC20Gateway(payable(address(gatewayProxy)));

        vm.prank(admin);
        factory.setPaymentGateway(address(gateway));

        address beacon = factory.beacon();
        vm.prank(admin);
        gateway.setOtherSide(false, remoteGateway, sourceChainId, address(peggedImplementation), address(factory), beacon);

        // The bridge only dispatches `_receiveMessage` into registered gateways (and
        // symmetrically only accepts `sendMessage` to registered destinations), so register
        // the freshly deployed gateway once upfront. We also register `remoteGateway`
        // because tests exercise the send path (`gateway.sendTokens(...)`) which calls
        // `bridge.sendMessage(remoteGateway, ...)`. Per-test ad-hoc receivers (e.g.
        // `NoopReceiver`) are registered lazily inside `_relayMessage`.
        _registerGateway(address(gateway));
        _registerGateway(remoteGateway);

        // Deploy the shared fast-withdrawal allowlist and wire it into the gateway. The
        // gateway must also be registered as a consumer on the list so `_consumeLimit` is
        // allowed to debit the rate caps. Tests that want to exercise the optimistic-
        // withdrawal safety policy then call `gateway.setWhitelistEnabled(true)` and
        // `fastWithdrawalList.registerToken(...)` to admit tokens to the allowlist.
        _deployFastWithdrawalList();
        vm.prank(admin);
        gateway.setFastWithdrawalList(address(fastWithdrawalList));
        bytes32 consumerRole = fastWithdrawalList.CONSUMER_ROLE();
        vm.prank(admin);
        fastWithdrawalList.grantRole(consumerRole, address(gateway));

        originToken = new MockERC20Token("Mock Token", "MOCK", 1_000_000 ether, user);
    }

    function _bridgeMessageHash(
        address from,
        address to,
        uint256 value,
        uint256 chainId,
        uint256 blockNumber,
        uint256 nonce,
        bytes memory message
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(from, to, value, chainId, blockNumber, nonce, message));
    }

    function _relayMessage(
        address from,
        address to,
        uint256 value,
        bytes memory message
    ) internal returns (bytes32 messageHash, uint256 nonce, uint256 sourceBlock) {
        // Auto-register the receive target so every test-delivered message reaches
        // `_receiveMessage` (the bridge rejects unregistered `to`). Idempotent.
        _registerGateway(to);

        nonce = bridge.getReceivedNonce();
        sourceBlock = nextSourceBlock++;
        messageHash = _bridgeMessageHash(from, to, value, sourceChainId, sourceBlock, nonce, message);

        vm.deal(address(bridge), address(bridge).balance + value);
        vm.prank(relayer);
        bridge.receiveMessage(from, to, value, sourceChainId, sourceBlock, nonce, message);
    }

    function _retryFailedMessage(address from, address to, uint256 value, uint256 blockNumber, uint256 nonce, bytes memory message) internal {
        // Defensive: ensure the target is registered for the retry as well.
        _registerGateway(to);

        vm.deal(address(bridge), address(bridge).balance + value);
        vm.prank(relayer);
        bridge.receiveFailedMessage(from, to, value, sourceChainId, blockNumber, nonce, message);
    }

    function _predictedPegged() internal view returns (address) {
        return gateway.computeTokenAddress(address(gateway), address(originToken));
    }

    /**
     * @dev Forces the local bridge to report that the currently executing receive originated
     *      from a Preconfirmed L1 batch. The gateway's `_consumeLimit` only enforces limits
     *      while the batch is Preconfirmed; outside of that window it's a no-op. Tests that
     *      want to exercise the limit path call this helper right before `_relayMessage`.
     */
    function _mockBridgePreconfirmed(bool value) internal {
        vm.mockCall(address(bridge), abi.encodeWithSelector(IFluentBridgeRead.isCurrentBatchPreconfirmed.selector), abi.encode(value));
    }
}
