// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {L2FluentBridge} from "../../../contracts/bridge/L2/L2FluentBridge.sol";
import {UniversalTokenFactory} from "../../../contracts/factories/UniversalTokenFactory.sol";
import {ERC20Gateway} from "../../../contracts/gateways/ERC20Gateway.sol";
import {NativeGateway} from "../../../contracts/gateways/NativeGateway.sol";
import {CommonBase} from "../../../lib/forge-std/src/Base.sol";
import {Script} from "../../../lib/forge-std/src/Script.sol";
import {StdChains} from "../../../lib/forge-std/src/StdChains.sol";
import {StdCheatsSafe} from "../../../lib/forge-std/src/StdCheats.sol";
import {StdUtils} from "../../../lib/forge-std/src/StdUtils.sol";
import {console} from "../../../lib/forge-std/src/console.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract MigrateL2 is Script {
    function run() external {
        /// ############################################################################################################
        ///  ========================================== TODO: update this
        /// ############################################################################################################

        L1_CHAIN_ID = 1;
        L1_START_BLOCK = 1000_0000000000;
        L1_GAS_PRICE = 1000000000000000000;

        address SUBMITTER = address();
        address FEE_TREASURY = address(0x9ec3f0d76A6d3847d86374c791C6E170CAd9518D);

        address payable bridgeProxy = payable(address(0x9CAcf613fC29015893728563f423fD26dCdB8Ddc));
        address payable erc20GatewayProxy = payable(address(0xFD4C62647A34FF6d6802092F5fbe176099223B61));
        address payable nativeGatewayProxy = payable(address(0x8976Ca4E0c8467097Da675399fB7DB454a1b56dd));
        address payable universalFactoryProxy = payable(address(0xF6d49E874Cb64b8ee56D6F99BD340134B30AB225));

        address payable l1BlockOracle = payable(address(0x19e1b30C792E417BC1827f5E2F288052b5c05e8F));
        address payable l1GasOracle = payable(address(0x207FBb4AC5227Ab598B8072BdC1E150dF687AC5B));

        /// TODO!
        address otherSideTokenImplementation = address();
        address otherSideFactoryBeacon = address();

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

        ///  ========================================== TODO: update this

        L2FluentBridge(bridgeProxy).setFeeTreasury(FEE_TREASURY);
        L2FluentBridge(bridgeProxy).setGasPriceConfig(0, 1000000000000000000, 200000);

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
        L1BlockOracle(l1BlockOracle).setSubmitter(SUBMITTER);
        L1BlockOracle(l1BlockOracle).setL1BlockNumber(L1_START_BLOCK);

        /// 6. L1GasOracle
        L1GasOracle(l1GasOracle).setSubmitter(SUBMITTER);
        L1GasOracle(l1GasOracle).setL1GasPrice(L1_GAS_PRICE);

        vm.stopBroadcast();
    }
}
