// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IFluentBridge, IFluentBridgeRead} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {L1BlockOracle} from "../../contracts/oracles/L1BlockOracle.sol";
import {L1GasOracle} from "../../contracts/oracles/L1GasOracle.sol";
import {ERC721Gateway} from "../../contracts/gateways/ERC721Gateway.sol";
import {ERC721TokenFactory} from "../../contracts/gateways/ERC721TokenFactory.sol";
import {ERC721PeggedToken} from "../../contracts/gateways/ERC721PeggedToken.sol";
import {MockERC721} from "../mocks/MockERC721.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {FastWithdrawalList} from "../../contracts/fastlist/FastWithdrawalList.sol";
import {NoopReceiver} from "../Bridge/Base.t.sol";

abstract contract ERC721GatewayBase is Test {
    address internal admin = makeAddr("admin");
    address internal relayer = makeAddr("relayer");
    address internal user = makeAddr("user");
    address internal recipient;
    address internal remoteBridge = makeAddr("remoteBridge");
    address internal remoteGateway;

    uint256 internal sourceChainId;
    uint256 internal nextSourceBlock = 2;

    IFluentBridge internal bridge;
    L1BlockOracle internal oracle;
    ERC721TokenFactory internal factory;
    ERC721Gateway internal gateway;
    ERC721PeggedToken internal peggedImplementation;
    MockERC721 internal originNft;
    FastWithdrawalList internal fastWithdrawalList;

    function setUp() public virtual {
        sourceChainId = block.chainid + 1;
        // EOAs accept ERC721 mint/transfer; {NoopReceiver} is not IERC721-compatible and would make _safeMint/safeTransferFrom revert.
        recipient = makeAddr("recipient");
        remoteGateway = address(new NoopReceiver());
    }

    function _deployBridge() internal {
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

    function _registerGateway(address target) internal {
        (bool isRegOk, bytes memory ret) = address(bridge).staticcall(
            abi.encodeWithSignature("isGatewayRegistered(address)", target)
        );
        if (isRegOk && ret.length == 32 && abi.decode(ret, (bool))) return;
        vm.prank(admin);
        (bool ok, ) = address(bridge).call(abi.encodeWithSignature("registerGateway(address)", target));
        if (!ok) {
            (isRegOk, ret) = address(bridge).staticcall(abi.encodeWithSignature("isGatewayRegistered(address)", target));
            require(isRegOk && ret.length == 32 && abi.decode(ret, (bool)), "registerGateway failed");
        }
    }

    function _deployFastWithdrawalList() internal {
        FastWithdrawalList listImpl = new FastWithdrawalList();
        ERC1967Proxy listProxy = new ERC1967Proxy(address(listImpl), abi.encodeCall(FastWithdrawalList.initialize, (admin)));
        fastWithdrawalList = FastWithdrawalList(address(listProxy));
    }

    function _deployERC721GatewayStack() internal {
        peggedImplementation = new ERC721PeggedToken();

        ERC721TokenFactory factoryImpl = new ERC721TokenFactory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(ERC721TokenFactory.initialize, (admin, address(peggedImplementation)))
        );
        factory = ERC721TokenFactory(address(factoryProxy));

        ERC721Gateway gatewayImpl = new ERC721Gateway();
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(
            address(gatewayImpl),
            abi.encodeCall(ERC721Gateway.initialize, (admin, address(bridge), address(factory)))
        );
        gateway = ERC721Gateway(payable(address(gatewayProxy)));

        vm.prank(admin);
        factory.setPaymentGateway(address(gateway));

        address beacon = factory.beacon();
        vm.prank(admin);
        gateway.setOtherSide(remoteGateway, sourceChainId, address(peggedImplementation), address(factory), beacon);

        _registerGateway(address(gateway));
        _registerGateway(remoteGateway);

        _deployFastWithdrawalList();
        vm.prank(admin);
        gateway.setFastWithdrawalList(address(fastWithdrawalList));
        bytes32 consumerRole = fastWithdrawalList.CONSUMER_ROLE();
        vm.prank(admin);
        fastWithdrawalList.grantRole(consumerRole, address(gateway));

        originNft = new MockERC721("Mock Collection", "MCOL");
        vm.prank(user);
        originNft.mint(user, 1);
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
        _registerGateway(to);
        nonce = bridge.getReceivedNonce();
        sourceBlock = nextSourceBlock++;
        messageHash = _bridgeMessageHash(from, to, value, sourceChainId, sourceBlock, nonce, message);
        vm.deal(address(bridge), address(bridge).balance + value);
        vm.prank(relayer);
        bridge.receiveMessage(from, to, value, sourceChainId, sourceBlock, nonce, message);
    }

    function _predictedPegged() internal view returns (address) {
        return gateway.computeTokenAddress(address(gateway), address(originNft));
    }

    function _bridgeFee() internal view returns (uint256) {
        return IFluentBridgeRead(address(bridge)).getSentMessageFee();
    }

    function _mockBridgePreconfirmed(bool value) internal {
        vm.mockCall(address(bridge), abi.encodeWithSelector(IFluentBridgeRead.isCurrentBatchPreconfirmed.selector), abi.encode(value));
    }
}
