// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IStakeManager} from "account-abstraction/interfaces/IStakeManager.sol";

import {AppDeposit} from "../../contracts/connect/AppDeposit.sol";
import {IAppDeposit} from "../../contracts/interfaces/connect/IAppDeposit.sol";
import {EthRejecter} from "../mocks/EthRejecter.sol";

contract AppDepositTest is Test {
    string internal constant APP_ID = "0b7e3c1a-4f2d-4e8b-9a6c-5d1f2e3a4b5c";
    /// @dev `cast keccak` of APP_ID, the topic the settler filters on.
    bytes32 internal constant APP_ID_HASH = 0x01414f4a886e9620dbd2c4987a8339206c1056304b61c19baa4ed9149d1d5d60;

    IStakeManager internal entryPoint;
    AppDeposit internal appDeposit;
    address internal member = makeAddr("member");
    /// @dev Any contract will do: the deposit only requires the paymaster to have code.
    address internal paymaster;

    function setUp() public {
        // A real EntryPoint v0.7, placed at its canonical address as on every Network.
        vm.etch(0x0000000071727De22E5E9d8BAf0edAc6f37da032, address(new EntryPoint()).code);
        entryPoint = IStakeManager(0x0000000071727De22E5E9d8BAf0edAc6f37da032);
        appDeposit = new AppDeposit();
        paymaster = address(new EthRejecter());
        vm.deal(member, 10 ether);
    }

    function test_deposit_creditsPaymasterEntryPointDeposit() public {
        entryPoint.depositTo{value: 0.5 ether}(paymaster);

        vm.prank(member);
        appDeposit.deposit{value: 1.25 ether}(APP_ID, paymaster);

        assertEq(entryPoint.balanceOf(paymaster), 1.75 ether);
        assertEq(address(appDeposit).balance, 0);
        assertEq(member.balance, 8.75 ether);
    }

    function test_deposit_emitsDepositedNamingTheApp() public {
        vm.expectEmit(address(appDeposit));
        emit IAppDeposit.Deposited(APP_ID_HASH, paymaster, member, APP_ID, 0.3 ether);

        vm.prank(member);
        appDeposit.deposit{value: 0.3 ether}(APP_ID, paymaster);
    }

    function test_deposit_revertsOnZeroValue() public {
        vm.prank(member);
        vm.expectRevert(IAppDeposit.ZeroValue.selector);
        appDeposit.deposit(APP_ID, paymaster);
    }

    function test_deposit_revertsOnAppIdNot36Bytes() public {
        string[3] memory badIds = ["", "0b7e3c1a-4f2d-4e8b-9a6c-5d1f2e3a4b5", "0b7e3c1a-4f2d-4e8b-9a6c-5d1f2e3a4b5c7"];
        uint256[3] memory lengths = [uint256(0), 35, 37];
        for (uint256 i = 0; i < badIds.length; i++) {
            vm.prank(member);
            vm.expectRevert(abi.encodeWithSelector(IAppDeposit.InvalidAppIdLength.selector, lengths[i]));
            appDeposit.deposit{value: 1 ether}(badIds[i], paymaster);
        }
    }

    function test_deposit_revertsOnPaymasterWithoutCode() public {
        address eoa = makeAddr("eoa");
        vm.prank(member);
        vm.expectRevert(abi.encodeWithSelector(IAppDeposit.PaymasterHasNoCode.selector, eoa));
        appDeposit.deposit{value: 1 ether}(APP_ID, eoa);
    }
}
