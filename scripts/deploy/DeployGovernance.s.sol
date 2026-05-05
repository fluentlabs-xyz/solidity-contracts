// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Governance} from "../../contracts/governance/Governance.sol";
import {IChainConfig} from "../../contracts/staking/interfaces/IChainConfig.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys the validator-owner governance contract behind a UUPS-compatible ERC1967 proxy.
/// @dev Use this standalone script when staking and chain config proxies already exist. Fresh staking module
///      deployments should prefer `DeployStaking`, which predicts and wires governance alongside staking.
contract DeployGovernance is DeployBase {
    using stdJson for string;

    struct GovernanceDeployment {
        address governance;
        address governanceImpl;
    }

    struct GovernanceDeployParams {
        address initialOwner;
        IStaking staking;
        IChainConfig chainConfig;
        uint32 votingPeriod;
    }

    function _readGovernanceParams() internal view returns (GovernanceDeployParams memory p) {
        (, string memory json) = _readActiveConfig();
        p.initialOwner = vm.envOr("INITIAL_OWNER", json.readAddress(".roles.initialOwner"));
        p.staking = IStaking(vm.envAddress("STAKING_ADDRESS"));
        p.chainConfig = IChainConfig(vm.envAddress("CHAIN_CONFIG_ADDRESS"));
        _assertHasCode(address(p.staking), "STAKING_ADDRESS");
        _assertHasCode(address(p.chainConfig), "CHAIN_CONFIG_ADDRESS");
        p.votingPeriod = uint32(vm.envOr("GOVERNANCE_VOTING_PERIOD", uint256(172_800)));
    }

    function _deployGovernance(GovernanceDeployParams memory p) internal returns (GovernanceDeployment memory r) {
        Governance governanceImpl = new Governance(p.staking, p.chainConfig);
        r.governance = address(
            new ERC1967Proxy(
                address(governanceImpl), abi.encodeCall(Governance.initialize, (p.initialOwner, p.votingPeriod))
            )
        );
        r.governanceImpl = address(governanceImpl);
    }

    function run() external {
        TargetChain memory chain = _activeChain();
        GovernanceDeployParams memory p = _readGovernanceParams();
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying governance");
        console2.log("  chain:", chain.chain);
        console2.log("  network:", chain.network);
        console2.log("  owner:", p.initialOwner);
        console2.log("  staking:", address(p.staking));
        console2.log("  chain config:", address(p.chainConfig));
        console2.log("  voting period:", p.votingPeriod);

        vm.startBroadcast();
        GovernanceDeployment memory r = _deployGovernance(p);
        vm.stopBroadcast();

        console2.log("Governance deployed:", r.governance);
        console2.log("  impl:", r.governanceImpl);

        if (bytes(outputPath).length != 0) {
            string memory out = vm.serializeAddress("deployment", "governance", r.governance);
            out = vm.serializeAddress("deployment", "governance_impl", r.governanceImpl);
            vm.writeJson(out, outputPath);
        }
    }
}
