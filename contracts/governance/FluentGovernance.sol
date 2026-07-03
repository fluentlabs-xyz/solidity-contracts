// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.30;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {GovernorUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import {
    GovernorCountingSimpleUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import {GovernorSettingsUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IChainConfig} from "../staking/interfaces/IChainConfig.sol";
import {IFluentGovernance} from "../staking/interfaces/IFluentGovernance.sol";
import {IStaking} from "../staking/interfaces/IStaking.sol";

/// @title Validator-owner governance
/// @notice Governor implementation whose voting power comes from active validator stake.
/// @dev Validator owners propose and vote, but votes are counted per validator address so ownership rotation cannot
///      double-count an already-cast validator vote. Mutable governance state uses ERC-7201 namespaced storage.
contract FluentGovernance is
    Initializable,
    GovernorUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorSettingsUpgradeable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    IFluentGovernance
{
    IStaking internal immutable _stakingContract;
    IChainConfig internal immutable _chainConfigContract;

    uint256 internal transient _instantVotingPeriod;

    modifier onlyValidatorOwner(address account) {
        require(_stakingContract.isValidatorActive(_stakingContract.getValidatorByOwner(account)), OnlyValidatorOwner());
        _;
    }

    constructor(IStaking stakingContract, IChainConfig chainConfigContract) {
        _stakingContract = stakingContract;
        _chainConfigContract = chainConfigContract;
        // Disable initializer for UUPS proxy contract
        _disableInitializers();
    }

    function initialize(address initialOwner, uint32 initialVotingPeriod) external initializer {
        __Governor_init("FluentGovernance");
        __GovernorCountingSimple_init();
        __GovernorSettings_init(0, initialVotingPeriod, 0);
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
    }

    function clock() public view virtual override returns (uint48) {
        return uint48(block.number);
    }

    function CLOCK_MODE() public view virtual override returns (string memory) {
        return "mode=blocknumber&from=default";
    }

    function getVotingSupply() external view returns (uint256) {
        return _votingSupply(block.number);
    }

    function getVotingPower(address validatorOwner) external view returns (uint256) {
        return _validatorOwnerVotingPowerAt(validatorOwner, block.number);
    }

    function proposeWithCustomVotingPeriod(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        uint256 customVotingPeriod
    ) public virtual onlyValidatorOwner(msg.sender) returns (uint256) {
        _instantVotingPeriod = customVotingPeriod;
        uint256 proposalId = propose(targets, values, calldatas, description);
        _instantVotingPeriod = 0;
        return proposalId;
    }

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public virtual override(GovernorUpgradeable) onlyValidatorOwner(msg.sender) returns (uint256) {
        return GovernorUpgradeable.propose(targets, values, calldatas, description);
    }

    function votingPeriod() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        if (_instantVotingPeriod != 0) return _instantVotingPeriod;

        return GovernorSettingsUpgradeable.votingPeriod();
    }

    function _getVotes(address account, uint256 timepoint, bytes memory) internal view virtual override returns (uint256) {
        return _validatorOwnerVotingPowerAt(account, timepoint);
    }

    function _countVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256 weight,
        bytes memory params
    ) internal virtual override(GovernorUpgradeable, GovernorCountingSimpleUpgradeable) {
        address validatorAddress = _stakingContract.getValidatorByOwner(account);
        super._countVote(proposalId, validatorAddress, support, weight, params);
    }

    function _validatorOwnerVotingPowerAt(address validatorOwner, uint256 blockNumber) internal view returns (uint256) {
        address validator = _stakingContract.getValidatorByOwner(validatorOwner);
        if (!_stakingContract.isValidatorActive(validator)) {
            return 0;
        }
        return _validatorVotingPowerAt(validator, blockNumber);
    }

    function _validatorVotingPowerAt(address validator, uint256 blockNumber) internal view returns (uint256) {
        uint64 epoch = uint64(blockNumber / _chainConfigContract.getEpochBlockInterval());
        (, , uint256 totalDelegated, , , , , , ) = _stakingContract.getValidatorStatusAtEpoch(validator, epoch);
        return totalDelegated;
    }

    function _votingSupply(uint256 blockNumber) internal view returns (uint256 votingSupply) {
        address[] memory validators = _stakingContract.getValidators();
        for (uint256 i = 0; i < validators.length; i++) {
            votingSupply += _validatorVotingPowerAt(validators[i], blockNumber);
        }
    }

    function quorum(uint256 blockNumber) public view override returns (uint256) {
        return (_votingSupply(blockNumber) * 2) / 3;
    }

    function votingDelay() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return GovernorSettingsUpgradeable.votingDelay();
    }

    function proposalThreshold() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return GovernorSettingsUpgradeable.proposalThreshold();
    }

    function supportsInterface(bytes4 interfaceId) public view override(GovernorUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
