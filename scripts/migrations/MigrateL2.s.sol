// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {L2FluentBridge} from "../../contracts/bridge/L2/L2FluentBridge.sol";
import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";
import {ERC20Gateway} from "../../contracts/gateways/ERC20Gateway.sol";
import {NativeGateway} from "../../contracts/gateways/NativeGateway.sol";
import {CommonBase} from "../../lib/forge-std/src/Base.sol";
import {Script} from "../../lib/forge-std/src/Script.sol";
import {StdChains} from "../../lib/forge-std/src/StdChains.sol";
import {StdCheatsSafe} from "../../lib/forge-std/src/StdCheats.sol";
import {StdUtils} from "../../lib/forge-std/src/StdUtils.sol";
import {console} from "../../lib/forge-std/src/console.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract MigrateL2 is Script {
    function run() external {
        address payable bridgeProxy = payable(address(0x9CAcf613fC29015893728563f423fD26dCdB8Ddc));
        address payable erc20GatewayProxy = payable(address(0xFD4C62647A34FF6d6802092F5fbe176099223B61));
        address payable nativeGatewayProxy = payable(address(0x8976Ca4E0c8467097Da675399fB7DB454a1b56dd));
        address payable universalFactoryProxy = payable(address(0xF6d49E874Cb64b8ee56D6F99BD340134B30AB225));

        require(bridgeProxy.code.length > 0, "proxy has no code");

        vm.startBroadcast();
//        address newbridgeImpl = address(new L2FluentBridge());
//        UnsafeUpgrades.upgradeProxy(bridgeProxy, newbridgeImpl, "");
//        console2.log("bridge", bridgeProxy, "->", newbridgeImpl);
//
//        address newErc20GatewayImpl = address(new ERC20Gateway());
//        UnsafeUpgrades.upgradeProxy(erc20GatewayProxy, newErc20GatewayImpl, "");
//        console2.log("erc20Gateway", erc20GatewayProxy, "->", newErc20GatewayImpl);
//
//        address newNativeGatewayImpl = address(new NativeGateway());
//        UnsafeUpgrades.upgradeProxy(nativeGatewayProxy, newNativeGatewayImpl, "");
//        console2.log("nativeGateway", nativeGatewayProxy, "->", newNativeGatewayImpl);
//
//        address newUniversalFactoryImpl = address(new UniversalTokenFactory());
//        UnsafeUpgrades.upgradeProxy(universalFactoryProxy, newUniversalFactoryImpl, "");
//        console2.log("universalFactory", universalFactoryProxy, "->", newUniversalFactoryImpl);
//
        L2FluentBridge(bridgeProxy).setOtherBridge(address(0x9CAcf613fC29015893728563f423fD26dCdB8Ddc));
        L2FluentBridge(bridgeProxy).setFeeTreasury(address(0x9ec3f0d76A6d3847d86374c791C6E170CAd9518D));
        L2FluentBridge(bridgeProxy).setGasPriceConfig(0, 1000000000000000000, 200000);
        L2FluentBridge(bridgeProxy).setL1BlockOracle(address(0x19e1b30C792E417BC1827f5E2F288052b5c05e8F));
        L2FluentBridge(bridgeProxy).setL1GasPriceOracle(address(0x207FBb4AC5227Ab598B8072BdC1E150dF687AC5B));
        NativeGateway(nativeGatewayProxy).setBridgeContract(address(0x9CAcf613fC29015893728563f423fD26dCdB8Ddc));
        NativeGateway(nativeGatewayProxy).setOtherSideGateway(address(0x8976Ca4E0c8467097Da675399fB7DB454a1b56dd));

        ERC20Gateway(erc20GatewayProxy).setBridgeContract(address(0x9CAcf613fC29015893728563f423fD26dCdB8Ddc));
        ERC20Gateway(erc20GatewayProxy).setTokenFactory(address(0xF6d49E874Cb64b8ee56D6F99BD340134B30AB225));
        ERC20Gateway(erc20GatewayProxy).setOtherSide(false, address(0xFD4C62647A34FF6d6802092F5fbe176099223B61), 11155111, address(0x57125e0DE1dd238154558643b1e78FCBf5Ab1A92), address(0xF6d49E874Cb64b8ee56D6F99BD340134B30AB225), address(0xdD283a04cc711aB9c08d79e665835821BEef710B));

        UniversalTokenFactory(universalFactoryProxy).setPaymentGateway(erc20GatewayProxy);

        vm.stopBroadcast();
    }
}
