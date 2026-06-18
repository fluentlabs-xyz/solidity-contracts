// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {GenericTokenFactory} from "./GenericTokenFactory.sol";

contract ERC721TokenFactory is GenericTokenFactory {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address implementation) external initializer {
        __GenericTokenFactory_init(initialOwner);
        require(implementation != address(0), ZeroAddressNotAllowed("Implementation"));
        _setBeacon(address(new UpgradeableBeacon(implementation, address(this))));
    }

    function deployToken(address gateway, address originToken, bytes calldata deployArgs)
        external
        override
        onlyPaymentGateway
        returns (address)
    {
        address tokenAddress = _deployToken(gateway, originToken, deployArgs);
        _afterDeployToken(tokenAddress, originToken);
        emit TokenDeployed(originToken, tokenAddress);
        return tokenAddress;
    }

    function _deployToken(address gateway, address originToken, bytes calldata) internal override returns (address) {
        require(gateway != address(0), ZeroAddressNotAllowed("Gateway"));
        require(originToken != address(0), ZeroAddressNotAllowed("OriginToken"));
        return Create2.deploy(0, _calculateSalt(gateway, originToken), _beaconProxyBytecode(beacon()));
    }

    function getDeployArgs(string memory, string memory, uint8) external pure override returns (bytes memory) {
        return bytes("");
    }

    function _computeTokenAddress(address gateway, address originToken, bytes calldata)
        internal
        view
        override
        returns (address)
    {
        return Create2.computeAddress(_calculateSalt(gateway, originToken), keccak256(_beaconProxyBytecode(beacon())));
    }
}
