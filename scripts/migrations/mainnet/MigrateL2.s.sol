// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import "../../../contracts/oracles/L1BlockOracle.sol";
import "../../../contracts/oracles/L1GasOracle.sol";
import {CommonBase} from "../../../lib/forge-std/src/Base.sol";
import {ERC20Gateway} from "../../../contracts/gateways/ERC20Gateway.sol";
import {L2FluentBridge} from "../../../contracts/bridge/L2/L2FluentBridge.sol";
import {NativeGateway} from "../../../contracts/gateways/NativeGateway.sol";
import {Script} from "../../../lib/forge-std/src/Script.sol";
import {StdChains} from "../../../lib/forge-std/src/StdChains.sol";
import {StdCheatsSafe} from "../../../lib/forge-std/src/StdCheats.sol";
import {StdUtils} from "../../../lib/forge-std/src/StdUtils.sol";
import {UniversalTokenFactory} from "../../../contracts/factories/UniversalTokenFactory.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {console2} from "../../../lib/forge-std/src/console2.sol";

contract MigrateL2 is Script {
    function run() external {
        uint256 L1_CHAIN_ID = 1;
        uint256 L1_START_BLOCK = 24893739;
        uint256 L1_GAS_PRICE = 251000000;

        address FEE_TREASURY = address(0x4A0e88275dC08a15Bad0d12e7805574Ca0853A48);

        address payable bridgeProxy = payable(address(0x9CAcf613fC29015893728563f423fD26dCdB8Ddc));
        address payable erc20GatewayProxy = payable(address(0xFD4C62647A34FF6d6802092F5fbe176099223B61));
        address payable nativeGatewayProxy = payable(address(0x8976Ca4E0c8467097Da675399fB7DB454a1b56dd));
        address payable universalFactoryProxy = payable(address(0xF6d49E874Cb64b8ee56D6F99BD340134B30AB225));
        address payable erc20TokenFactoryProxy = payable(address(0xF6d49E874Cb64b8ee56D6F99BD340134B30AB225));

        address payable l1BlockOracle = payable(address(0x19e1b30C792E417BC1827f5E2F288052b5c05e8F));
        address payable l1GasOracle = payable(address(0x207FBb4AC5227Ab598B8072BdC1E150dF687AC5B));

        address otherSideTokenImplementation = address(0x056fD0A3eD85c6ae1Ec1c398B33581951Ed4b090);
        address otherSideFactoryBeacon = address(0xdD283a04cc711aB9c08d79e665835821BEef710B);

        vm.startBroadcast();

        //////////// UPGRADE PROXIES ////////////

        /// 1. L1FluentBridge
        address newbridgeImpl = address(new L2FluentBridge());
        UnsafeUpgrades.upgradeProxy(bridgeProxy, newbridgeImpl, "");
        console2.log("bridge", bridgeProxy, "->", newbridgeImpl);

        /// 2. ERC20Gateway
        address newErc20GatewayImpl = address(new ERC20Gateway());
        UnsafeUpgrades.upgradeProxy(erc20GatewayProxy, newErc20GatewayImpl, "");
        console2.log("erc20Gateway", erc20GatewayProxy, "->", newErc20GatewayImpl);

        /// 3. NativeGateway
        address newNativeGatewayImpl = address(new NativeGateway());
        UnsafeUpgrades.upgradeProxy(nativeGatewayProxy, newNativeGatewayImpl, "");
        console2.log("nativeGateway", nativeGatewayProxy, "->", newNativeGatewayImpl);

        /// 4. UniversalTokenFactory
        address newUniversalFactoryImpl = address(new UniversalTokenFactory());
        UnsafeUpgrades.upgradeProxy(universalFactoryProxy, newUniversalFactoryImpl, "");
        console2.log("universalFactory", universalFactoryProxy, "->", newUniversalFactoryImpl);

        //////////// SET CONTRACTS ////////////

        /// 1. L1FluentBridge
        L2FluentBridge(bridgeProxy).setOtherBridge(bridgeProxy);
        L2FluentBridge(bridgeProxy).setExecuteGasLimit(500_000);

        L2FluentBridge(bridgeProxy).setFeeTreasury(FEE_TREASURY);
        L2FluentBridge(bridgeProxy).setGasPriceConfig(0, 1200000000000000000, 300000);

        L2FluentBridge(bridgeProxy).setL1BlockOracle(l1BlockOracle);
        L2FluentBridge(bridgeProxy).setL1GasPriceOracle(l1GasOracle);

        /// 2. NativeGateway
        NativeGateway(nativeGatewayProxy).setBridgeContract(bridgeProxy);
        NativeGateway(nativeGatewayProxy).setOtherSideGateway(nativeGatewayProxy);

        /// 3. ERC20Gateway
        ERC20Gateway(erc20GatewayProxy).setBridgeContract(bridgeProxy);
        ERC20Gateway(erc20GatewayProxy).setTokenFactory(erc20TokenFactoryProxy);
        ERC20Gateway(erc20GatewayProxy).setOtherSide(
            false,
            erc20GatewayProxy,
            L1_CHAIN_ID,
            otherSideTokenImplementation, // otherSideTokenImplementation
            universalFactoryProxy, // otherSideFactory
            otherSideFactoryBeacon
        );

        /// 4. UniversalTokenFactory
        UniversalTokenFactory(universalFactoryProxy).setPaymentGateway(erc20GatewayProxy);

        /// 5. L1BlockOracle
        L1BlockOracle(l1BlockOracle).setSubmitter(0xf1af41d33CfFdc8d08107713c0c2DF5De7f2Bd5c);
        L1BlockOracle(l1BlockOracle).setL1BlockNumber(L1_START_BLOCK);

        /// 6. L1GasOracle
        L1GasOracle(l1GasOracle).setSubmitter(0x1Bee0BD77E76aD9692F6A3b4388DdE371b69fdD7);
        L1GasOracle(l1GasOracle).setL1GasPrice(L1_GAS_PRICE);

        vm.stopBroadcast();
    }
}
