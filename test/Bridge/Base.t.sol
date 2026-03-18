// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {FluentBridge} from "../../contracts/bridge/FluentBridge.sol";
import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {L1BlockOracle} from "../../contracts/oracle/L1BlockOracle.sol";
import {PaymentGateway} from "../../contracts/gateways/PaymentGateway.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {MockERC20Token} from "../../contracts/mocks/MockERC20.sol";

contract NoopReceiver {
    uint256 public calls;

    function handle() external payable {
        calls += 1;
    }
}

contract RevertingReceiver {
    function fail() external payable {
        revert("receiver-failed");
    }
}

contract RejectEther {
    receive() external payable {
        revert("reject-eth");
    }
}

abstract contract BridgeGatewayBase is Test {
    address internal admin = makeAddr("admin");
    address internal relayer = makeAddr("relayer");
    address internal user = makeAddr("user");
    address internal recipient = makeAddr("recipient");
    address internal remoteBridge = makeAddr("remoteBridge");
    address internal remoteGateway = makeAddr("remoteGateway");

    uint256 internal sourceChainId;
    uint256 internal nextSourceBlock = 1;

    FluentBridge internal bridge;
    L1BlockOracle internal oracle;
    ERC20TokenFactory internal factory;
    PaymentGateway internal gateway;
    ERC20PeggedToken internal peggedImplementation;
    MockERC20Token internal originToken;

    function setUp() public virtual {
        sourceChainId = block.chainid + 1;
    }

    function _deployBridge(uint256 receiveMessageDeadline) internal {
        oracle = new L1BlockOracle();

        FluentBridge impl = new FluentBridge();
        FluentBridge.InitConfiguration memory params = FluentBridge.InitConfiguration({
            adminRole: admin,
            pauserRole: admin,
            relayerRole: relayer,
            rollup: address(0),
            receiveMessageDeadline: receiveMessageDeadline,
            otherBridge: remoteBridge,
            l1BlockOracle: receiveMessageDeadline == 0 ? address(0) : address(oracle)
        });

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(FluentBridge.initialize, (abi.encode(params))));
        bridge = FluentBridge(payable(address(proxy)));
    }

    function _deployGatewayStack() internal {
        peggedImplementation = new ERC20PeggedToken();

        ERC20TokenFactory factoryImpl = new ERC20TokenFactory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(ERC20TokenFactory.initialize, (admin, address(peggedImplementation)))
        );
        factory = ERC20TokenFactory(address(factoryProxy));

        PaymentGateway gatewayImpl = new PaymentGateway();
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(
            address(gatewayImpl),
            abi.encodeCall(PaymentGateway.initialize, (admin, address(bridge), address(factory)))
        );
        gateway = PaymentGateway(payable(address(gatewayProxy)));

        vm.prank(admin);
        factory.setPaymentGateway(address(gateway));

        address beacon = factory.beacon();
        vm.prank(admin);
        gateway.setOtherSide(remoteGateway, address(peggedImplementation), address(factory), beacon);

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
        nonce = bridge.receivedNonce();
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
