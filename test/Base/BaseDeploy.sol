// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {FluentBridgeStorageLayout} from "../../contracts/bridge/FluentBridgeStorageLayout.sol";
import {L1BlockOracle} from "../../contracts/oracles/L1BlockOracle.sol";
import {L1GasOracle} from "../../contracts/oracles/L1GasOracle.sol";
import {NativeGateway} from "../../contracts/gateways/NativeGateway.sol";
import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";
import {MockERC20Token} from "../../test/mocks/MockERC20.sol";
import {InitConfiguration} from "../../contracts/interfaces/IRollupTypes.sol";
import {MockNitroVerifier} from "../mocks/MockNitroVerifier.sol";
import {MockSp1Verifier} from "../mocks/MockSp1Verifier.sol";

abstract contract BaseDeployNative is Test {
    uint256 internal constant RECEIVE_DEADLINE = 100;
    bytes32 internal constant GENESIS_HASH = keccak256("genesis");
    bytes32 internal constant PROGRAM_VKEY = keccak256("vkey");
    bytes internal constant DUMMY_SIGNATURE = abi.encodePacked(keccak256("r"), keccak256("s"), uint8(27));
    uint256 internal constant FINALIZATION_DELAY = 1;
    uint256 internal constant MAX_FORCE_REVERT_BATCH_SIZE = 10;

    // Fork ids
    uint256 internal l1ForkId;
    uint256 internal l2ForkId;
    uint256 internal l1ChainId;
    uint256 internal l2ChainId;

    // Actors
    address internal admin;
    address internal relayer;
    address internal l1Sender;
    address internal l2Recipient;
    address internal l1Recipient;

    // L1 contracts
    L1FluentBridge internal l1Bridge;
    NativeGateway internal l1Gateway;
    Rollup internal l1Rollup;
    MockNitroVerifier internal l1NitroVerifier;

    // L2 contracts
    L2FluentBridge internal l2Bridge;
    NativeGateway internal l2Gateway;
    L1BlockOracle internal l2BlockOracle;
    L1GasOracle internal l2GasOracle;

    function _selectL1() internal {
        vm.selectFork(l1ForkId);
    }

    function _selectL2() internal {
        vm.selectFork(l2ForkId);
    }

    function _deployOnL1() internal {
        _selectL1();

        l1NitroVerifier = new MockNitroVerifier();
        MockSp1Verifier sp1 = new MockSp1Verifier();

        InitConfiguration memory cfg;
        cfg.admin = admin;
        cfg.emergency = admin;
        cfg.sequencer = relayer;
        cfg.challenger = address(0);
        cfg.prover = address(0);
        cfg.preconfirmationRole = relayer;
        cfg.sp1Verifier = address(sp1);
        cfg.nitroVerifier = address(l1NitroVerifier);
        cfg.bridge = address(0xB1);
        cfg.programVKey = PROGRAM_VKEY;
        cfg.genesisHash = GENESIS_HASH;
        cfg.challengeDepositAmount = 1 ether;
        cfg.challengeWindow = 0;
        cfg.finalizationDelay = FINALIZATION_DELAY;
        cfg.acceptDepositDeadline = 1000;
        cfg.incentiveFee = 0;
        cfg.submitBlobsWindow = 0;
        cfg.preconfirmWindow = 1;
        cfg.maxForceRevertBatchSize = MAX_FORCE_REVERT_BATCH_SIZE;

        Rollup rollupImpl = new Rollup();
        ERC1967Proxy rollupProxy = new ERC1967Proxy(address(rollupImpl), abi.encodeCall(Rollup.initialize, (abi.encode(cfg))));
        l1Rollup = Rollup(payable(address(rollupProxy)));

        FluentBridgeStorageLayout.InitConfiguration memory params = FluentBridgeStorageLayout.InitConfiguration({
            adminRole: admin,
            pauserRole: admin,
            relayerRole: relayer,
            otherBridge: address(0xB1)
        });

        L1FluentBridge bridgeImpl = new L1FluentBridge();
        ERC1967Proxy bridgeProxy = new ERC1967Proxy(
            address(bridgeImpl),
            abi.encodeCall(L1FluentBridge.initialize, (abi.encode(params), address(l1Rollup)))
        );
        l1Bridge = L1FluentBridge(payable(address(bridgeProxy)));

        NativeGateway gatewayImpl = new NativeGateway();
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(address(gatewayImpl), abi.encodeCall(NativeGateway.initialize, (admin, address(l1Bridge))));
        l1Gateway = NativeGateway(payable(address(gatewayProxy)));
    }

    function _deployOnL2() internal {
        _selectL2();

        l2BlockOracle = new L1BlockOracle(address(this));
        l2GasOracle = new L1GasOracle(relayer);

        FluentBridgeStorageLayout.InitConfiguration memory params = FluentBridgeStorageLayout.InitConfiguration({
            adminRole: admin,
            pauserRole: admin,
            relayerRole: relayer,
            otherBridge: address(0xB2)
        });

        L2FluentBridge bridgeImpl = new L2FluentBridge();
        ERC1967Proxy bridgeProxy = new ERC1967Proxy(
            address(bridgeImpl),
            abi.encodeCall(
                L2FluentBridge.initialize,
                (abi.encode(params), RECEIVE_DEADLINE, address(l2BlockOracle), address(l2GasOracle), 0, 0, 0, makeAddr("feeTreasury"))
            )
        );
        l2Bridge = L2FluentBridge(payable(address(bridgeProxy)));

        NativeGateway gatewayImpl = new NativeGateway();
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(address(gatewayImpl), abi.encodeCall(NativeGateway.initialize, (admin, address(l2Bridge))));
        l2Gateway = NativeGateway(payable(address(gatewayProxy)));
    }
}

abstract contract BaseDeployERC20 is Test {
    uint256 internal constant RECEIVE_DEADLINE = 100;
    bytes32 internal constant GENESIS_HASH = keccak256("genesis");
    bytes32 internal constant PROGRAM_VKEY = keccak256("vkey");
    bytes internal constant DUMMY_SIGNATURE = abi.encodePacked(keccak256("r"), keccak256("s"), uint8(27));
    uint256 internal constant FINALIZATION_DELAY = 1;
    uint256 internal constant MAX_FORCE_REVERT_BATCH_SIZE = 10;

    uint256 internal l1ForkId;
    uint256 internal l2ForkId;
    uint256 internal l1ChainId;
    uint256 internal l2ChainId;

    address internal admin;
    address internal relayer;
    address internal l1Sender;
    address internal l2Recipient;
    address internal l1Recipient;

    L1FluentBridge internal l1Bridge;
    L2FluentBridge internal l2Bridge;
    Rollup internal l1Rollup;
    MockNitroVerifier internal l1NitroVerifier;
    L1BlockOracle internal l1BlockOracle;
    L1GasOracle internal l1GasOracle;

    ERC20Gateway internal l1Gateway;
    ERC20Gateway internal l2Gateway;
    ERC20TokenFactory internal l1Factory;
    ERC20TokenFactory internal l2Factory;
    address internal l1FactoryBeacon;
    address internal l2FactoryBeacon;
    ERC20PeggedToken internal peggedImplL1;
    ERC20PeggedToken internal peggedImplL2;
    MockERC20Token internal originToken;

    function _selectL1() internal {
        vm.selectFork(l1ForkId);
    }

    function _selectL2() internal {
        vm.selectFork(l2ForkId);
    }

    function _deployOnL1() internal {
        _selectL1();

        l1NitroVerifier = new MockNitroVerifier();
        MockSp1Verifier sp1 = new MockSp1Verifier();

        InitConfiguration memory cfg;
        cfg.admin = admin;
        cfg.emergency = admin;
        cfg.sequencer = relayer;
        cfg.challenger = address(0);
        cfg.prover = address(0);
        cfg.preconfirmationRole = relayer;
        cfg.sp1Verifier = address(sp1);
        cfg.nitroVerifier = address(l1NitroVerifier);
        cfg.bridge = address(0xB1);
        cfg.programVKey = PROGRAM_VKEY;
        cfg.genesisHash = GENESIS_HASH;
        cfg.challengeDepositAmount = 1 ether;
        cfg.challengeWindow = 0;
        cfg.finalizationDelay = FINALIZATION_DELAY;
        cfg.acceptDepositDeadline = 1000;
        cfg.incentiveFee = 0;
        cfg.submitBlobsWindow = 0;
        cfg.preconfirmWindow = 1;
        cfg.maxForceRevertBatchSize = MAX_FORCE_REVERT_BATCH_SIZE;

        Rollup rollupImpl = new Rollup();
        ERC1967Proxy rollupProxy = new ERC1967Proxy(address(rollupImpl), abi.encodeCall(Rollup.initialize, (abi.encode(cfg))));
        l1Rollup = Rollup(payable(address(rollupProxy)));

        FluentBridgeStorageLayout.InitConfiguration memory params = FluentBridgeStorageLayout.InitConfiguration({
            adminRole: admin,
            pauserRole: admin,
            relayerRole: relayer,
            otherBridge: address(0xB1)
        });

        L1FluentBridge bridgeImpl = new L1FluentBridge();
        ERC1967Proxy bridgeProxy = new ERC1967Proxy(
            address(bridgeImpl),
            abi.encodeCall(L1FluentBridge.initialize, (abi.encode(params), address(l1Rollup)))
        );
        l1Bridge = L1FluentBridge(payable(address(bridgeProxy)));
        l1Bridge.setExecuteGasLimit(2_000_000);
        l1Rollup.setBridge(address(l1Bridge));

        peggedImplL1 = new ERC20PeggedToken();
        ERC20TokenFactory fImpl = new ERC20TokenFactory();
        ERC1967Proxy fProxy = new ERC1967Proxy(address(fImpl), abi.encodeCall(ERC20TokenFactory.initialize, (admin, address(peggedImplL1))));
        l1Factory = ERC20TokenFactory(payable(address(fProxy)));
        l1FactoryBeacon = l1Factory.beacon();

        ERC20Gateway gImpl = new ERC20Gateway();
        ERC1967Proxy gProxy = new ERC1967Proxy(
            address(gImpl),
            abi.encodeCall(ERC20Gateway.initialize, (admin, address(l1Bridge), address(l1Factory)))
        );
        l1Gateway = ERC20Gateway(payable(address(gProxy)));
        l1Factory.setPaymentGateway(address(l1Gateway));

        originToken = new MockERC20Token("Mock Token", "MOCK", 1_000_000 ether, l1Sender);
    }

    function _deployOnL2() internal {
        _selectL2();

        l1BlockOracle = new L1BlockOracle(address(this));
        l1GasOracle = new L1GasOracle(relayer);

        FluentBridgeStorageLayout.InitConfiguration memory params = FluentBridgeStorageLayout.InitConfiguration({
            adminRole: admin,
            pauserRole: admin,
            relayerRole: relayer,
            otherBridge: address(0xB2)
        });

        L2FluentBridge bridgeImpl = new L2FluentBridge();
        ERC1967Proxy bridgeProxy = new ERC1967Proxy(
            address(bridgeImpl),
            abi.encodeCall(
                L2FluentBridge.initialize,
                (abi.encode(params), RECEIVE_DEADLINE, address(l1BlockOracle), address(l1GasOracle), 0, 0, 0, makeAddr("feeTreasury"))
            )
        );
        l2Bridge = L2FluentBridge(payable(address(bridgeProxy)));
        l2Bridge.setExecuteGasLimit(2_000_000);

        peggedImplL2 = new ERC20PeggedToken();
        ERC20TokenFactory fImpl = new ERC20TokenFactory();
        ERC1967Proxy fProxy = new ERC1967Proxy(address(fImpl), abi.encodeCall(ERC20TokenFactory.initialize, (admin, address(peggedImplL2))));
        l2Factory = ERC20TokenFactory(payable(address(fProxy)));
        l2FactoryBeacon = l2Factory.beacon();

        ERC20Gateway gImpl = new ERC20Gateway();
        ERC1967Proxy gProxy = new ERC1967Proxy(
            address(gImpl),
            abi.encodeCall(ERC20Gateway.initialize, (admin, address(l2Bridge), address(l2Factory)))
        );
        l2Gateway = ERC20Gateway(payable(address(gProxy)));
        l2Factory.setPaymentGateway(address(l2Gateway));
    }
}
