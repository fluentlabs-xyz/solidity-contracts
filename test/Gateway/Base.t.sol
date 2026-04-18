// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {L1BlockOracle} from "../../contracts/oracles/L1BlockOracle.sol";
import {L1GasOracle} from "../../contracts/oracles/L1GasOracle.sol";
import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {MockERC20Token} from "../mocks/MockERC20.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {FluentBridgeStorageLayout} from "../../contracts/bridge/FluentBridgeStorageLayout.sol";

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
        nonce = bridge.getReceivedNonce();
        sourceBlock = nextSourceBlock++;
        messageHash = _bridgeMessageHash(from, to, value, sourceChainId, sourceBlock, nonce, message);

        vm.deal(address(bridge), address(bridge).balance + value);
        vm.prank(relayer);
        bridge.receiveMessage(from, to, value, sourceChainId, sourceBlock, nonce, message);
    }

    function _retryFailedMessage(address from, address to, uint256 value, uint256 blockNumber, uint256 nonce, bytes memory message) internal {
        vm.deal(address(bridge), address(bridge).balance + value);
        vm.prank(relayer);
        bridge.receiveFailedMessage(from, to, value, sourceChainId, blockNumber, nonce, message);
    }

    function _predictedPegged() internal view returns (address) {
        return gateway.computeTokenAddress(address(gateway), address(originToken));
    }
}
