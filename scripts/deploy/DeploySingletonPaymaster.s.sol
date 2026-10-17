// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {SingletonPaymasterV7} from "singleton-paymaster/SingletonPaymasterV7.sol";

/// @notice Deploys the Pimlico {SingletonPaymasterV7} that Fluent Connect sponsors with, funds and
///         stakes it at the EntryPoint, and writes its manifest.
///
/// @dev The contract is `pimlicolabs/singleton-paymaster` at commit
///      `1e2305d1102242379b582142f62bd17add12b8c2`, used as published from `lib/singleton-paymaster`:
///      there is no copy in `contracts/`. Only its verifying mode is used; ERC-20 mode is neither
///      used nor configured here.
///
///      Roles come from `ManagerAccessControl`, not `Ownable`: the constructor grants
///      `DEFAULT_ADMIN_ROLE` to `owner` and `MANAGER_ROLE` to `manager`, and either role may call
///      `addSigner`, `removeSigner` and `addStake`. A wrong `PAYMASTER_SIGNER` is therefore
///      recoverable without a redeploy — unlike the eth-infinitism sample this replaces — but a
///      wrong `ENV`, chain or deposit still wastes a deploy, so every refusal happens before the
///      broadcast opens.
///
///      `deposit()` and `addStake()` run in the same broadcast as the CREATE. `deposit()` is open to
///      anyone; `addStake` is `onlyAdminOrManager` and the broadcaster is the owner, so the three
///      calls share one sender.
///
/// Phases: (1) read and check settings, (2) broadcast deploy + deposit + stake, (3) write manifest JSON.
///
/// Environment:
/// - ENV (optional, default testnet) selects the manifest directory and the expected chain id.
/// - PAYMASTER_SIGNER (required) is the address of the service's `PAYMASTER_SIGNER_KEY`. The key
///   itself never enters this repo; only its address does.
/// - PAYMASTER_MANAGER (optional, default the broadcasting account) receives `MANAGER_ROLE`.
/// - DEPOSIT_WEI (optional, default 0.05 ether) is deposited at the EntryPoint for gas sponsorship.
/// - STAKE_WEI (optional, default 0.1 ether) is staked at the EntryPoint.
/// - UNSTAKE_DELAY_SEC (optional, default 86400) is the stake's unstake delay.
/// - OUTPUT_PATH (optional, default deployments/<ENV>/l2.singleton-paymaster.json) receives the manifest.
///
/// The manifest carries no `deployment_block`: a simulated `block.number` is not the mined one. The
/// block is read after the run from the paymaster's CREATE receipt in
/// `broadcast/DeploySingletonPaymaster.s.sol/<chainId>/run-latest.json` and added to the manifest and
/// to docs/Addresses.md by hand, together with the deployed runtime code hash and the compiler
/// settings of the build.
///
/// Run (testnet, keystore account):
///   ENV=testnet PAYMASTER_SIGNER=0x... \
///     forge script scripts/deploy/DeploySingletonPaymaster.s.sol:DeploySingletonPaymaster \
///     --rpc-url $L2_RPC --account $DEPLOYER --sender $SENDER --broadcast
contract DeploySingletonPaymaster is Script {
    /// @notice Everything a run needs, read from the environment and already checked.
    /// @param env The environment name, `testnet` or `mainnet`.
    /// @param manager The address that receives `MANAGER_ROLE`, or zero for the broadcasting account.
    /// @param signer The signer the paymaster's signer set starts with, non-zero.
    /// @param depositWei The EntryPoint deposit, greater than zero.
    /// @param stakeWei The EntryPoint stake.
    /// @param unstakeDelaySec The stake's unstake delay, narrowed to `uint32` after the range check.
    /// @param outputPath Where the manifest is written.
    /// @dev `owner` is not a field: it is the broadcasting account, which only {deploy} knows, since
    ///      `addStake` must be called by a role holder and `msg.sender` inside the broadcast is the
    ///      only account that holds one.
    struct Settings {
        string env;
        address manager;
        address signer;
        uint256 depositWei;
        uint256 stakeWei;
        uint32 unstakeDelaySec;
        string outputPath;
    }

    /// @notice The raw variables a run was given, before any parsing or checking.
    /// @dev An empty string means the variable is unset, so a `.env` line left blank falls back to
    ///      the default instead of failing to parse. Keeping the raw strings in one value lets the
    ///      refusals in {settings} be exercised without writing the process environment.
    struct Environment {
        string env;
        string paymasterSigner;
        string paymasterManager;
        string depositWei;
        string stakeWei;
        string unstakeDelaySec;
        string outputPath;
    }

    uint256 private constant FLUENT_TESTNET_CHAIN_ID = 20994;
    uint256 private constant FLUENT_MAINNET_CHAIN_ID = 25363;

    /// @dev The canonical ERC-4337 EntryPoint v0.7, at the same address on every Network.
    IEntryPoint private constant ENTRY_POINT = IEntryPoint(0x0000000071727De22E5E9d8BAf0edAc6f37da032);

    uint256 private constant DEFAULT_DEPOSIT_WEI = 0.05 ether;
    uint256 private constant DEFAULT_STAKE_WEI = 0.1 ether;
    uint256 private constant DEFAULT_UNSTAKE_DELAY_SEC = 86400;

    function run() external returns (SingletonPaymasterV7 paymaster) {
        // Phase 1: read and check. Every refusal lives in settings(), which returns before the
        // broadcast opens, so a refused run leaves no contract, no deposit and no manifest behind.
        return deploy(settings());
    }

    /// @notice Deploys, funds, stakes and records the paymaster for settings already checked.
    /// @dev Separate from {run} and not an overload of it: `forge script` refuses a script whose ABI
    ///      carries two functions named `run`.
    function deploy(Settings memory settings_) public returns (SingletonPaymasterV7 paymaster) {
        address[] memory signers = new address[](1);
        signers[0] = settings_.signer;

        console2.log("Deploying SingletonPaymasterV7");
        console2.log("  env:", settings_.env);
        console2.log("  signer:", settings_.signer);
        console2.log("  depositWei:", settings_.depositWei);
        console2.log("  stakeWei:", settings_.stakeWei);
        console2.log("  unstakeDelaySec:", settings_.unstakeDelaySec);
        console2.log("  outputPath:", settings_.outputPath);

        // Phase 2: deploy, fund and stake in one broadcast. The owner is the broadcasting account,
        // and the manager defaults to it, so the account the roles are granted to is the one
        // `addStake`'s onlyAdminOrManager accepts. The broadcaster is read with `vm.readCallers`,
        // not from `msg.sender`: `msg.sender` is whoever called this function, which is the sender
        // only when `forge script` calls `run()` and not when a test calls `deploy()`.
        vm.startBroadcast();
        (, address owner,) = vm.readCallers();
        address manager = settings_.manager == address(0) ? owner : settings_.manager;
        console2.log("  owner:", owner);
        console2.log("  manager:", manager);

        paymaster = new SingletonPaymasterV7(address(ENTRY_POINT), owner, manager, signers);
        paymaster.deposit{value: settings_.depositWei}();
        paymaster.addStake{value: settings_.stakeWei}(settings_.unstakeDelaySec);
        vm.stopBroadcast();

        // Phase 3: write manifest, reading the EntryPoint back from the deployed contract.
        string memory out = vm.serializeUint("singleton-paymaster", "chainId", block.chainid);
        out = vm.serializeAddress("singleton-paymaster", "entry_point", address(paymaster.entryPoint()));
        out = vm.serializeAddress("singleton-paymaster", "singleton_paymaster", address(paymaster));
        out = vm.serializeAddress("singleton-paymaster", "owner", owner);
        out = vm.serializeAddress("singleton-paymaster", "manager", manager);
        out = vm.serializeAddress("singleton-paymaster", "signers", signers);
        vm.writeJson(out, settings_.outputPath);

        console2.log("SingletonPaymasterV7:", address(paymaster));
        console2.log("Add deployment_block, the runtime code hash and the compiler settings to the");
        console2.log("manifest and docs/Addresses.md; the block comes from the CREATE receipt in broadcast/.");
    }

    /// @notice The seven variables a run reads, exactly as the process environment holds them.
    function environment() public view returns (Environment memory) {
        return Environment({
            env: vm.envOr("ENV", string("")),
            paymasterSigner: vm.envOr("PAYMASTER_SIGNER", string("")),
            paymasterManager: vm.envOr("PAYMASTER_MANAGER", string("")),
            depositWei: vm.envOr("DEPOSIT_WEI", string("")),
            stakeWei: vm.envOr("STAKE_WEI", string("")),
            unstakeDelaySec: vm.envOr("UNSTAKE_DELAY_SEC", string("")),
            outputPath: vm.envOr("OUTPUT_PATH", string(""))
        });
    }

    /// @notice The checked settings of the current process environment.
    function settings() public view returns (Settings memory) {
        return settings(environment());
    }

    /// @notice Applies the defaults and refuses every input the deploy must not be run with.
    /// @dev `UNSTAKE_DELAY_SEC == 0`, `STAKE_WEI == 0` and `STAKE_WEI > type(uint112).max` are left to
    ///      the EntryPoint's own reverts through `addStake` (`IStakeManager`'s `must specify unstake
    ///      delay`, `no stake specified` and `stake overflow`); nothing here narrows them, so they
    ///      need no check of their own. An oversized `UNSTAKE_DELAY_SEC` is different: `addStake`
    ///      takes a `uint32`, so an unchecked cast would wrap an operator's typo into a valid-looking
    ///      delay and EntryPoint would never see the value that was asked for. It is therefore
    ///      rejected here, before the cast.
    ///
    ///      `PAYMASTER_MANAGER` is left as zero when unset and resolved to the broadcaster in
    ///      {deploy}: the broadcasting account is not known at this point. A manager explicitly set
    ///      to the zero address is refused, because granting `MANAGER_ROLE` to `address(0)` would
    ///      silently produce a paymaster with no second role holder.
    function settings(Environment memory raw) public view returns (Settings memory) {
        string memory env = _or(raw.env, "testnet");
        require(block.chainid == _expectedChainId(env), "chain id does not match ENV");
        require(address(ENTRY_POINT).code.length > 0, "EntryPoint v0.7 not deployed");

        require(bytes(raw.paymasterSigner).length > 0, "PAYMASTER_SIGNER must be set");
        address signer = vm.parseAddress(raw.paymasterSigner);
        require(signer != address(0), "PAYMASTER_SIGNER must not be the zero address");

        address manager = address(0);
        if (bytes(raw.paymasterManager).length > 0) {
            manager = vm.parseAddress(raw.paymasterManager);
            require(manager != address(0), "PAYMASTER_MANAGER must not be the zero address");
        }

        uint256 depositWei = _orUint(raw.depositWei, DEFAULT_DEPOSIT_WEI);
        require(depositWei > 0, "DEPOSIT_WEI must be greater than zero");

        uint256 unstakeDelaySec = _orUint(raw.unstakeDelaySec, DEFAULT_UNSTAKE_DELAY_SEC);
        require(unstakeDelaySec <= type(uint32).max, "UNSTAKE_DELAY_SEC exceeds uint32");

        return Settings({
            env: env,
            manager: manager,
            signer: signer,
            depositWei: depositWei,
            stakeWei: _orUint(raw.stakeWei, DEFAULT_STAKE_WEI),
            // SAFE: the require above refuses anything above type(uint32).max, so this cannot wrap.
            // forge-lint: disable-next-line(unsafe-typecast)
            unstakeDelaySec: uint32(unstakeDelaySec),
            outputPath: _or(raw.outputPath, string.concat("deployments/", env, "/l2.singleton-paymaster.json"))
        });
    }

    function _or(string memory raw, string memory defaultValue) private pure returns (string memory) {
        return bytes(raw).length == 0 ? defaultValue : raw;
    }

    /// @dev Amounts are wei and seconds, in decimal or `0x` hex.
    function _orUint(string memory raw, uint256 defaultValue) private pure returns (uint256) {
        return bytes(raw).length == 0 ? defaultValue : vm.parseUint(raw);
    }

    function _expectedChainId(string memory env) internal pure returns (uint256) {
        if (keccak256(bytes(env)) == keccak256("testnet")) return FLUENT_TESTNET_CHAIN_ID;
        if (keccak256(bytes(env)) == keccak256("mainnet")) return FLUENT_MAINNET_CHAIN_ID;
        revert("ENV must be testnet or mainnet");
    }
}
