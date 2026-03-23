// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {GenericTokenFactory} from "./GenericTokenFactory.sol";

/**
 * @title ERC20TokenFactory
 * @author Fluent Labs
 * @notice Deploys ERC20 pegged tokens as BeaconProxy instances for the bridge; one UpgradeableBeacon per factory.
 * @dev Only callable by PaymentGateway or owner. keyData = abi.encode(gateway, originToken); deployArgs = "" (metadata comes from origin on first receive).
 *      Salt = keccak256(gateway, originToken). Owner can upgrade all pegged tokens at once via upgradeTo(newImplementation) on the beacon.
 * @notice Workflows:
 * 1. First receive of an origin token on this chain: gateway calls deployToken(keyData, deployArgs); factory deploys BeaconProxy with CREATE2 and registers origin -> pegged.
 * 2. Address prediction: computePeggedTokenAddress(keyData, "") and computeOtherSidePeggedTokenAddress(keyData, "") use same salt and beacon proxy bytecode for L1/L2 parity.
 * 3. getDeployArgs: returns empty bytes (ERC20 pegged tokens take name/symbol/decimals from origin token at receive time).
 */
contract ERC20TokenFactory is GenericTokenFactory {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the upgradeable factory (replaces constructor when used behind a proxy).
     * @param initialOwner Owner of the factory (e.g. gateway or deployer).
     * @param implementation Initial token implementation for the beacon.
     */
    function initialize(address initialOwner, address implementation) external initializer {
        __GenericTokenFactory_init(initialOwner);
        require(implementation != address(0), ZeroAddressNotAllowed("Implementation"));
        // dedicated beacon for ERC20 tokens deployment, so we don't need to use this contract as a beacon
        // factory owns the beacon so upgradeTo() can propagate to all pegged tokens
        address beacon = address(new UpgradeableBeacon(implementation, address(this)));

        _setBeacon(beacon);
    }

    // ============ Deploy functions ============

    /// @inheritdoc GenericTokenFactory
    function deployToken(
        address gateway,
        address originToken,
        bytes calldata deployArgs
    ) external override onlyPaymentGateway returns (address) {
        // deploy the BeaconProxy via CREATE2 for deterministic addressing
        address tokenAddress = _deployToken(gateway, originToken, deployArgs);
        // register origin->pegged and pegged->info mappings for later lookups
        _afterDeployToken(tokenAddress, originToken);

        emit TokenDeployed(originToken, tokenAddress);

        return tokenAddress;
    }

    /**
     * @dev Deploys a pegged ERC20 token as a BeaconProxy via CREATE2 with a deterministic salt.
     */
    function _deployToken(address gateway, address originToken, bytes calldata /*deployArgs*/) internal override returns (address) {
        require(gateway != address(0), ZeroAddressNotAllowed("Gateway"));
        require(originToken != address(0), ZeroAddressNotAllowed("OriginToken"));

        // salt ties address to gateway+origin pair so each combo gets exactly one token
        bytes32 salt = _calculateSalt(gateway, originToken);
        // BeaconProxy creation code with our beacon; no init data since metadata is set later
        bytes memory bytecode = _beaconProxyBytecode(beacon());

        // CREATE2 deploy for cross-chain address predictability
        return Create2.deploy(0, salt, bytecode);
    }

    // ============ Public view functions ============

    /**
     * @dev The deploy args are empty for ERC20 tokens as the token metadata is not needed.
     */
    function getDeployArgs(
        string memory /*tokenName*/,
        string memory /*tokenSymbol*/,
        uint8 /*decimals*/
    ) external pure override returns (bytes memory) {
        // ERC20 pegged tokens receive metadata from the origin token at first bridge, not at deploy
        return bytes("");
    }

    /// @inheritdoc GenericTokenFactory
    function _computeTokenAddress(address gateway, address originToken, bytes calldata /*deployArgs*/) internal view override returns (address) {
        // must use identical salt and bytecode as _deployToken to match the CREATE2 address
        bytes32 salt = _calculateSalt(gateway, originToken);
        bytes memory bytecode = _beaconProxyBytecode(beacon());
        return Create2.computeAddress(salt, keccak256(bytecode));
    }
}
