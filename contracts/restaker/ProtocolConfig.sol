// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts/utils/StorageSlot.sol";

import "./interfaces/IProtocolConfig.sol";
import "./restaker/IRestakerDeployer.sol";

contract ProtocolConfig is ContextUpgradeable, IProtocolConfig {
    using StorageSlot for bytes32;

    bytes32 internal constant _GOVERNANCE_SLOT =
        keccak256(
            abi.encode(uint256(keccak256("restaker.config.Governance")) - 1)
        ) & ~bytes32(uint256(0xff));
    bytes32 internal constant _OPERATOR_SLOT =
        keccak256(
            abi.encode(uint256(keccak256("restaker.config.Operator")) - 1)
        ) & ~bytes32(uint256(0xff));
    bytes32 internal constant _TREASURY_SLOT =
        keccak256(
            abi.encode(uint256(keccak256("restaker.config.Treasury")) - 1)
        ) & ~bytes32(uint256(0xff));
    bytes32 internal constant _RATIO_FEED_SLOT =
        keccak256(
            abi.encode(uint256(keccak256("restaker.config.RatioFeed")) - 1)
        ) & ~bytes32(uint256(0xff));
    bytes32 internal constant _RESTAKING_POOL_SLOT =
        keccak256(
            abi.encode(uint256(keccak256("restaker.config.RestakingPool")) - 1)
        ) & ~bytes32(uint256(0xff));
    bytes32 internal constant _CTOKEN_SLOT =
        keccak256(
            abi.encode(uint256(keccak256("restaker.config.cToken")) - 1)
        ) & ~bytes32(uint256(0xff));
    bytes32 internal constant _RESTAKER_DEPLOYER =
        keccak256(
            abi.encode(
                uint256(keccak256("restaker.config.RestakerDepoyer")) - 1
            )
        ) & ~bytes32(uint256(0xff));

    modifier onlyGovernance() virtual {
        if (_msgSender() != getGovernance()) {
            revert OnlyGovernanceAllowed();
        }
        _;
    }

    /*******************************************************************************
                        CONSTRUCTOR
    *******************************************************************************/

    /// @dev https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable#initializing_the_implementation_contract
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address governanceAddress,
        address operatorAddress,
        address treasuryAddress
    ) {
        __ProtocolConfig_init(
            operatorAddress,
            governanceAddress,
            treasuryAddress
        );
    }

    function __ProtocolConfig_init(
        address operator,
        address governance,
        address treasury
    ) internal {
        _setOperator(operator);
        _setGovernance(governance);
        _setTreasury(treasury);
    }

    /*******************************************************************************
                        WRITE FUNCTIONS
    *******************************************************************************/

    function setGovernance(address newValue) external onlyGovernance {
        _setGovernance(newValue);
    }

    function _setGovernance(address newValue) internal {
        _requireNotZero(newValue);
        emit GovernanceChanged(getGovernance(), newValue);
        _GOVERNANCE_SLOT.getAddressSlot().value = address(newValue);
    }

    function setOperator(address newValue) external onlyGovernance {
        _setOperator(newValue);
    }

    function _setOperator(address newValue) internal {
        _requireNotZero(newValue);
        emit OperatorChanged(getOperator(), newValue);
        _OPERATOR_SLOT.getAddressSlot().value = address(newValue);
    }

    function setTreasury(address newValue) external onlyGovernance {
        _setTreasury(newValue);
    }

    function _setTreasury(address newValue) internal {
        _requireNotZero(newValue);
        emit TreasuryChanged(getTreasury(), newValue);
        _TREASURY_SLOT.getAddressSlot().value = address(newValue);
    }

    function setRatioFeed(IRatioFeed newValue) external onlyGovernance {
        _requireNotZero(address(newValue));
        emit RatioFeedChanged(getRatioFeed(), newValue);
        _RATIO_FEED_SLOT.getAddressSlot().value = address(newValue);
    }

    function setRestakingPool(IRestakingPool newValue) external onlyGovernance {
        _requireNotZero(address(newValue));
        emit RestakingPoolChanged(getRestakingPool(), newValue);
        _RESTAKING_POOL_SLOT.getAddressSlot().value = address(newValue);
    }

    function setLiquidityToken(
        ILiquidityToken newValue
    ) external onlyGovernance {
        _requireNotZero(address(newValue));
        emit CTokenChanged(getLiquidityToken(), newValue);
        _CTOKEN_SLOT.getAddressSlot().value = address(newValue);
    }

    function setRestakerDeployer(
        IRestakerDeployer newValue
    ) external onlyGovernance {
        _requireNotZero(address(newValue));
        emit RestakerDeployerChanged(getRestakerDeployer(), newValue);
        _RESTAKER_DEPLOYER.getAddressSlot().value = address(newValue);
    }

    function _requireNotZero(address addr) internal pure {
        if (addr == address(0)) {
            revert ZeroAddress();
        }
    }

    /*******************************************************************************
                        READ FUNCTIONS
    *******************************************************************************/

    function getGovernance() public view virtual returns (address) {
        return _GOVERNANCE_SLOT.getAddressSlot().value;
    }

    function getOperator() public view virtual returns (address) {
        return _OPERATOR_SLOT.getAddressSlot().value;
    }

    function getTreasury() public view virtual returns (address) {
        return _TREASURY_SLOT.getAddressSlot().value;
    }

    function getRestakingPool() public view override returns (IRestakingPool) {
        return IRestakingPool(_RESTAKING_POOL_SLOT.getAddressSlot().value);
    }

    function getRatioFeed() public view override returns (IRatioFeed) {
        return IRatioFeed(_RATIO_FEED_SLOT.getAddressSlot().value);
    }

    function getLiquidityToken()
        public
        view
        override
        returns (ILiquidityToken)
    {
        return ILiquidityToken(_CTOKEN_SLOT.getAddressSlot().value);
    }

    function getLiquidityTokenAddress() external view returns (address) {
        return _CTOKEN_SLOT.getAddressSlot().value;
    }

    function getRestakerDeployer()
        public
        view
        override
        returns (IRestakerDeployer)
    {
        return IRestakerDeployer(_RESTAKER_DEPLOYER.getAddressSlot().value);
    }
}
