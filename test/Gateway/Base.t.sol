// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {L1BlockOracle} from "../../contracts/oracle/L1BlockOracle.sol";
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
    uint256 internal nextSourceBlock = 1;

    IFluentBridge internal bridge;
    L1BlockOracle internal oracle;
    ERC20TokenFactory internal factory;
    ERC20Gateway internal gateway;
    ERC20PeggedToken internal peggedImplementation;
    MockERC20Token internal originToken;

    function setUp() public virtual {
        sourceChainId = block.chainid + 1;
    }

    function _deployBridge(uint256 receiveMessageDeadline) internal {
        oracle = new L1BlockOracle(admin);

        L2FluentBridge impl = new L2FluentBridge();
        FluentBridgeStorageLayout.InitConfiguration memory params = FluentBridgeStorageLayout.InitConfiguration({
            adminRole: admin,
            pauserRole: admin,
            relayerRole: relayer,
            otherBridge: remoteBridge
        });

        // Gateway tests rely on the trusted relayer path (receiveMessage),
        // which exists on L2 bridge and needs a deadline + oracle config.
        uint256 deadline = receiveMessageDeadline == 0 ? 1 : receiveMessageDeadline;
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(L2FluentBridge.initialize, (abi.encode(params), deadline, address(oracle)))
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

        vm.deal(relayer, value);
        vm.prank(relayer);
        bridge.receiveMessage{value: value}(from, to, value, sourceChainId, sourceBlock, nonce, message);
    }

    function _retryFailedMessage(address from, address to, uint256 value, uint256 blockNumber, uint256 nonce, bytes memory message) internal {
        vm.deal(relayer, value);
        vm.prank(relayer);
        bridge.receiveFailedMessage{value: value}(from, to, value, sourceChainId, blockNumber, nonce, message);
    }

    function _predictedPegged() internal view returns (address) {
        return gateway.computePeggedTokenAddress(address(originToken));
    }
}
