// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC20PeggedToken} from "../../../contracts/tokens/ERC20PeggedToken.sol";
import {L1FluentBridge} from "../../../contracts/bridge/L1/L1FluentBridge.sol";
import {ERC20TokenFactory} from "../../../contracts/factories/ERC20TokenFactory.sol";
import {ERC20Gateway} from "../../../contracts/gateways/ERC20Gateway.sol";
import {NativeGateway} from "../../../contracts/gateways/NativeGateway.sol";
import {CommonBase} from "../../../lib/forge-std/src/Base.sol";
import {Script} from "../../../lib/forge-std/src/Script.sol";
import {StdChains} from "../../../lib/forge-std/src/StdChains.sol";
import {StdCheatsSafe} from "../../../lib/forge-std/src/StdCheats.sol";
import {StdUtils} from "../../../lib/forge-std/src/StdUtils.sol";
import {console2} from "../../../lib/forge-std/src/console2.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract MigrateL1 is Script {
    function run() external {
        uint256 L2_CHAIN_ID = 25363;
        uint256 RECEIVE_MESSAGE_DEADLINE = 7200;
        uint256 DEPOSIT_PROCESSING_WINDOW = 7200;
        uint256 EXECUTE_GAS_LIMIT = 5_000;

        address payable bridgeProxy = payable(address(0x9CAcf613fC29015893728563f423fD26dCdB8Ddc));
        address payable rollupProxy = payable(address(0x1cF53Fd9CD0b713be29F2b41cA17A943f138727f));
        address payable erc20GatewayProxy = payable(address(0xFD4C62647A34FF6d6802092F5fbe176099223B61));
        address payable nativeGatewayProxy = payable(address(0x8976Ca4E0c8467097Da675399fB7DB454a1b56dd));
        address payable erc20TokenFactoryProxy = payable(address(0xF6d49E874Cb64b8ee56D6F99BD340134B30AB225));
        address payable beaconUpgradeable = payable(address(0xdD283a04cc711aB9c08d79e665835821BEef710B));

        vm.startBroadcast();

        //////////// UPGRADE PROXIES ////////////

        /// 1. L1FluentBridge
        address newbridgeImpl = address(new L1FluentBridge());
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

        /// 4. ERC20TokenFactory
        address newErc20TokenFactoryImpl = address(new ERC20TokenFactory());
        UnsafeUpgrades.upgradeProxy(erc20TokenFactoryProxy, newErc20TokenFactoryImpl, "");
        console2.log("erc20TokenFactory", erc20TokenFactoryProxy, "->", newErc20TokenFactoryImpl);

        /// 5. PeggedImpl
        address newPeggedImpl = address(new ERC20PeggedToken());
        console2.log("peggedImpl", newPeggedImpl);

        //////////// SET CONTRACTS ////////////

        /// 1. L1FluentBridge
        L1FluentBridge(bridgeProxy).setOtherBridge(bridgeProxy);
        L1FluentBridge(bridgeProxy).setExecuteGasLimit(EXECUTE_GAS_LIMIT);

        L1FluentBridge(bridgeProxy).setRollup(rollupProxy);
        L1FluentBridge(bridgeProxy).setReceiveMessageDeadline(RECEIVE_MESSAGE_DEADLINE);
        L1FluentBridge(bridgeProxy).setDepositProcessingWindow(DEPOSIT_PROCESSING_WINDOW);

        /// 2. NativeGateway
        NativeGateway(nativeGatewayProxy).setBridgeContract(bridgeProxy);
        NativeGateway(nativeGatewayProxy).setOtherSideGateway(nativeGatewayProxy);

        /// 3. ERC20Gateway
        ERC20Gateway(erc20GatewayProxy).setBridgeContract(bridgeProxy);
        ERC20Gateway(erc20GatewayProxy).setTokenFactory(erc20TokenFactoryProxy);
        ERC20Gateway(erc20GatewayProxy).setOtherSide(
            true,
            erc20GatewayProxy, // otherSideGateway
            L2_CHAIN_ID, // otherSideChainId
            address(0x0000000000000000000000000000000000520008), // otherSideTokenImplementation
            erc20TokenFactoryProxy, // otherSideFactory
            address(0x0) // otherSideBeacon
        );

        /// 4. ERC20TokenFactory
        ERC20TokenFactory(erc20TokenFactoryProxy).setBeacon(beaconUpgradeable);
        ERC20TokenFactory(erc20TokenFactoryProxy).upgradeTo(newPeggedImpl);
        ERC20TokenFactory(erc20TokenFactoryProxy).setPaymentGateway(erc20GatewayProxy);

        vm.stopBroadcast();
    }
}
