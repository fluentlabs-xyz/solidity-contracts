// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IStakeManager} from "account-abstraction/interfaces/IStakeManager.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

// The paymaster's own copy of the ERC-4337 types. It is the same commit as this repo's
// lib/account-abstraction (v0.7.0), but a different path makes a different Solidity type, and
// `getHash` and `validatePaymasterUserOp` take the paymaster's one.
import {PackedUserOperation} from "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import {SingletonPaymasterV7} from "singleton-paymaster/SingletonPaymasterV7.sol";

import {DeploySingletonPaymaster} from "../../scripts/deploy/DeploySingletonPaymaster.s.sol";

/// @dev The canonical ERC-4337 EntryPoint v0.7 address, the same on every Network.
address constant ENTRY_POINT_ADDRESS = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
uint256 constant FLUENT_TESTNET_CHAIN_ID = 20994;
uint256 constant FLUENT_MAINNET_CHAIN_ID = 25363;

/// @dev Verifying mode is 0 and the lowest bit of the mode byte is `allowAllBundlers`, so the byte
///      `0x01` means "verifying mode, any bundler" (`BaseSingletonPaymaster._parsePaymasterAndData`).
uint8 constant VERIFYING_MODE = 0;

/// @notice {DeploySingletonPaymaster} refuses every input it must not deploy with before it opens a
///         broadcast, and otherwise deploys, funds and stakes the paymaster from one sender.
///
/// @dev The refusals are asserted over {DeploySingletonPaymaster.settings}, the function `run()`
///      calls before anything else, given an `Environment` value instead of the process environment:
///      `vm.setEnv` writes one environment shared by every test Foundry runs in parallel, so a test
///      that mutates it cannot be isolated. One test does exercise the process environment end to
///      end — {test_environment_isReadFromTheDocumentedVariableNames} — and it is the only writer.
contract DeploySingletonPaymasterTest is Test {
    uint256 internal constant DEFAULT_DEPOSIT_WEI = 0.05 ether;
    uint256 internal constant DEFAULT_STAKE_WEI = 0.1 ether;
    uint256 internal constant DEFAULT_UNSTAKE_DELAY_SEC = 86400;

    /// @dev Fixed test addresses, never a service signer: the script only ever reads the address.
    address internal constant SIGNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant MANAGER = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    DeploySingletonPaymaster internal deployScript;

    function setUp() public {
        vm.chainId(FLUENT_TESTNET_CHAIN_ID);
        // A real EntryPoint v0.7 at its canonical address: the deposit and the stake must land in it.
        // The paymaster's own constructor does not check the address, which is why the script does.
        vm.etch(ENTRY_POINT_ADDRESS, address(new EntryPoint()).code);
        deployScript = new DeploySingletonPaymaster();
        vm.deal(DEFAULT_SENDER, 10 ether);
    }

    // ─── Refusals, before anything is broadcast ───────────────────────────────

    function test_settings_refusesAnEnvThatNamesNoChain() public {
        DeploySingletonPaymaster.Environment memory raw = _validEnvironment();
        raw.env = "staging";
        _assertRefused(raw, "ENV must be testnet or mainnet");
    }

    function test_settings_refusesAChainIdThatDoesNotMatchEnv() public {
        DeploySingletonPaymaster.Environment memory raw = _validEnvironment();
        raw.env = "mainnet";
        _assertRefused(raw, "chain id does not match ENV");

        vm.chainId(FLUENT_MAINNET_CHAIN_ID);
        raw.env = "testnet";
        _assertRefused(raw, "chain id does not match ENV");
    }

    /// @dev `BasePaymaster`'s constructor stores the EntryPoint address without checking it, so a
    ///      wrong chain would leave a paymaster whose deposit and stake can never be made.
    function test_settings_refusesAChainWithoutEntryPoint() public {
        vm.etch(ENTRY_POINT_ADDRESS, "");
        _assertRefused(_validEnvironment(), "EntryPoint v0.7 not deployed");
    }

    function test_settings_refusesAnUnsetPaymasterSigner() public {
        DeploySingletonPaymaster.Environment memory raw = _validEnvironment();
        raw.paymasterSigner = "";
        _assertRefused(raw, "PAYMASTER_SIGNER must be set");
    }

    function test_settings_refusesTheZeroPaymasterSigner() public {
        DeploySingletonPaymaster.Environment memory raw = _validEnvironment();
        raw.paymasterSigner = vm.toString(address(0));
        _assertRefused(raw, "PAYMASTER_SIGNER must not be the zero address");
    }

    /// @dev Unset means "the broadcasting account" and is resolved in `deploy`; an explicit zero is a
    ///      typo that would grant MANAGER_ROLE to nobody.
    function test_settings_refusesTheZeroPaymasterManager() public {
        DeploySingletonPaymaster.Environment memory raw = _validEnvironment();
        raw.paymasterManager = vm.toString(address(0));
        _assertRefused(raw, "PAYMASTER_MANAGER must not be the zero address");
    }

    /// @dev A paymaster with no deposit sponsors nothing, and FLU-1589's on-save check requires a
    ///      non-zero deposit, so an unfunded run wastes a deploy and a verification.
    function test_settings_refusesAZeroDeposit() public {
        DeploySingletonPaymaster.Environment memory raw = _validEnvironment();
        raw.depositWei = "0";
        _assertRefused(raw, "DEPOSIT_WEI must be greater than zero");
    }

    /// @dev `addStake` takes a `uint32`, so an unchecked cast would turn this typo into the default
    ///      delay and lock the stake for a duration nobody asked for.
    function test_settings_refusesAnUnstakeDelayThatWouldWrapToUint32() public {
        uint256 oversized = uint256(type(uint32).max) + 1 + DEFAULT_UNSTAKE_DELAY_SEC;
        // SAFE: the truncation is what this line asserts, and it is the hazard under test.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(uint32(oversized), DEFAULT_UNSTAKE_DELAY_SEC, "the fixture must be a value that would wrap");

        DeploySingletonPaymaster.Environment memory raw = _validEnvironment();
        raw.unstakeDelaySec = vm.toString(oversized);
        _assertRefused(raw, "UNSTAKE_DELAY_SEC exceeds uint32");
    }

    // ─── Defaults and explicit values ─────────────────────────────────────────

    function test_settings_usesTheDocumentedDefaultsForUnsetVariables() public view {
        DeploySingletonPaymaster.Environment memory raw;
        raw.paymasterSigner = vm.toString(SIGNER);

        DeploySingletonPaymaster.Settings memory settings = deployScript.settings(raw);

        assertEq(settings.env, "testnet");
        assertEq(settings.signer, SIGNER);
        // Zero stands for "the broadcasting account", which only `deploy` knows.
        assertEq(settings.manager, address(0));
        assertEq(settings.depositWei, DEFAULT_DEPOSIT_WEI);
        assertEq(settings.stakeWei, DEFAULT_STAKE_WEI);
        assertEq(settings.unstakeDelaySec, DEFAULT_UNSTAKE_DELAY_SEC);
        assertEq(settings.outputPath, "deployments/testnet/l2.singleton-paymaster.json");
    }

    function test_settings_takesEveryValueFromTheEnvironmentWhenItIsSet() public {
        vm.chainId(FLUENT_MAINNET_CHAIN_ID);

        DeploySingletonPaymaster.Environment memory raw = DeploySingletonPaymaster.Environment({
            env: "mainnet",
            paymasterSigner: vm.toString(SIGNER),
            paymasterManager: vm.toString(MANAGER),
            depositWei: "123",
            stakeWei: "456",
            unstakeDelaySec: vm.toString(uint256(type(uint32).max)),
            outputPath: ""
        });

        DeploySingletonPaymaster.Settings memory settings = deployScript.settings(raw);

        assertEq(settings.env, "mainnet");
        assertEq(settings.signer, SIGNER);
        assertEq(settings.manager, MANAGER);
        assertEq(settings.depositWei, 123);
        assertEq(settings.stakeWei, 456);
        assertEq(settings.unstakeDelaySec, type(uint32).max);
        // `ENV=mainnet` is supported so the later mainnet deploy is the same command.
        assertEq(settings.outputPath, "deployments/mainnet/l2.singleton-paymaster.json");
    }

    // ─── The deploy itself ────────────────────────────────────────────────────

    function test_run_deploysFundsAndStakesFromOneSender() public {
        SingletonPaymasterV7 paymaster = deployScript.deploy(_settingsWritingTo("deploy"));

        assertEq(address(paymaster.entryPoint()), ENTRY_POINT_ADDRESS);
        assertTrue(paymaster.signers(SIGNER), "the signer set must start with PAYMASTER_SIGNER");
        // The roles are AccessControl roles, not Ownable: owner is DEFAULT_ADMIN_ROLE, manager is
        // MANAGER_ROLE. `addStake` is onlyAdminOrManager, so the stake lands only because the CREATE
        // and both funding calls share one broadcaster.
        assertTrue(paymaster.hasRole(0x00, DEFAULT_SENDER), "the broadcaster must be the owner");
        assertTrue(paymaster.hasRole(paymaster.MANAGER_ROLE(), DEFAULT_SENDER), "unset manager is the broadcaster");

        IStakeManager.DepositInfo memory info = IStakeManager(ENTRY_POINT_ADDRESS).getDepositInfo(address(paymaster));
        assertEq(info.deposit, DEFAULT_DEPOSIT_WEI);
        assertTrue(info.staked);
        assertEq(info.stake, DEFAULT_STAKE_WEI);
        assertEq(info.unstakeDelaySec, DEFAULT_UNSTAKE_DELAY_SEC);
    }

    /// @dev Separate owner and manager roles are one of the reasons this contract replaces the
    ///      eth-infinitism sample, so a `PAYMASTER_MANAGER` that is not the deployer must land.
    function test_run_grantsManagerRoleToPaymasterManagerWhenItIsSet() public {
        DeploySingletonPaymaster.Settings memory settings = _settingsWritingTo("manager");
        settings.manager = MANAGER;

        SingletonPaymasterV7 paymaster = deployScript.deploy(settings);

        assertTrue(paymaster.hasRole(0x00, DEFAULT_SENDER), "the broadcaster is still the owner");
        assertTrue(paymaster.hasRole(paymaster.MANAGER_ROLE(), MANAGER));
        assertFalse(paymaster.hasRole(paymaster.MANAGER_ROLE(), DEFAULT_SENDER));
    }

    /// @dev Phase B of FLU-1590 adds `deployment_block` from the CREATE receipt, and FLU-1589 reads
    ///      the address and the signers, so a renamed or missing key breaks both.
    function test_run_writesTheManifestWithoutASimulatedBlock() public {
        DeploySingletonPaymaster.Settings memory settings = _settingsWritingTo("manifest");
        SingletonPaymasterV7 paymaster = deployScript.deploy(settings);

        string memory manifest = vm.readFile(settings.outputPath);
        assertEq(vm.parseJsonUint(manifest, ".chainId"), FLUENT_TESTNET_CHAIN_ID);
        assertEq(vm.parseJsonAddress(manifest, ".entry_point"), ENTRY_POINT_ADDRESS);
        assertEq(vm.parseJsonAddress(manifest, ".singleton_paymaster"), address(paymaster));
        assertEq(vm.parseJsonAddress(manifest, ".owner"), DEFAULT_SENDER);
        assertEq(vm.parseJsonAddress(manifest, ".manager"), DEFAULT_SENDER);

        address[] memory signers = vm.parseJsonAddressArray(manifest, ".signers");
        assertEq(signers.length, 1);
        assertEq(signers[0], SIGNER);

        string[] memory keys = vm.parseJsonKeys(manifest, "$");
        assertEq(keys.length, 6, "the manifest carries exactly the six keys this phase can know");
        assertFalse(vm.keyExistsJson(manifest, ".deployment_block"), "a simulated block is not the mined one");
    }

    // ─── The wiring to the process environment ────────────────────────────────

    /// @dev The one test that writes the process environment, so nothing else can race it. It covers
    ///      the variable names an operator sets, and that a refused `run()` writes no manifest: a
    ///      manifest write is file IO, which a revert does not roll back, so the file's absence
    ///      proves the run stopped before its broadcast and its manifest phase.
    function test_environment_isReadFromTheDocumentedVariableNames() public {
        string memory manifestPath = _scratchPath("environment");
        vm.setEnv("ENV", "testnet");
        vm.setEnv("PAYMASTER_SIGNER", vm.toString(SIGNER));
        vm.setEnv("PAYMASTER_MANAGER", vm.toString(MANAGER));
        vm.setEnv("DEPOSIT_WEI", "7");
        vm.setEnv("STAKE_WEI", "8");
        vm.setEnv("UNSTAKE_DELAY_SEC", "9");
        vm.setEnv("OUTPUT_PATH", manifestPath);

        DeploySingletonPaymaster.Environment memory raw = deployScript.environment();
        assertEq(raw.env, "testnet");
        assertEq(raw.paymasterSigner, vm.toString(SIGNER));
        assertEq(raw.paymasterManager, vm.toString(MANAGER));
        assertEq(raw.depositWei, "7");
        assertEq(raw.stakeWei, "8");
        assertEq(raw.unstakeDelaySec, "9");
        assertEq(raw.outputPath, manifestPath);

        DeploySingletonPaymaster.Settings memory settings = deployScript.settings();
        assertEq(settings.signer, SIGNER);
        assertEq(settings.manager, MANAGER);
        assertEq(settings.depositWei, 7);
        assertEq(settings.stakeWei, 8);
        assertEq(settings.unstakeDelaySec, 9);
        assertEq(settings.outputPath, manifestPath);

        // A refused environment stops the no-argument run() before it broadcasts or records anything.
        vm.setEnv("PAYMASTER_SIGNER", vm.toString(address(0)));
        assertFalse(vm.exists(manifestPath), "a manifest existed before the run");
        vm.expectRevert(bytes("PAYMASTER_SIGNER must not be the zero address"));
        deployScript.run();
        assertFalse(vm.exists(manifestPath), "the refused run still wrote a manifest");
    }

    function _validEnvironment() internal pure returns (DeploySingletonPaymaster.Environment memory raw) {
        raw.env = "testnet";
        raw.paymasterSigner = vm.toString(SIGNER);
        raw.depositWei = vm.toString(DEFAULT_DEPOSIT_WEI);
        raw.stakeWei = vm.toString(DEFAULT_STAKE_WEI);
        raw.unstakeDelaySec = vm.toString(DEFAULT_UNSTAKE_DELAY_SEC);
    }

    function _assertRefused(DeploySingletonPaymaster.Environment memory raw, string memory reason) internal {
        vm.expectRevert(bytes(reason));
        deployScript.settings(raw);
    }

    /// @dev Checked settings whose manifest goes to this test's own git-ignored scratch file, so no
    ///      test can write a real `deployments/<ENV>/` manifest or race another test's file.
    function _settingsWritingTo(string memory name) internal returns (DeploySingletonPaymaster.Settings memory) {
        DeploySingletonPaymaster.Settings memory settings = deployScript.settings(_validEnvironment());
        settings.outputPath = _scratchPath(name);
        if (vm.exists(settings.outputPath)) vm.removeFile(settings.outputPath);
        return settings;
    }

    function _scratchPath(string memory name) internal pure returns (string memory) {
        return string.concat("cache/flu-1590-singleton-paymaster.", name, ".test.json");
    }
}

/// @notice The committed reference vectors for FLU-1589: `validatePaymasterUserOp`, called by the
///         EntryPoint, accepts a signature by a signer in the set over the EIP-191 digest of
///         `getHash`, reports a failure rather than reverting for any other key, and follows
///         `removeSigner` and `addSigner` without a redeploy.
///
/// @dev The vector fixes the chain id and the paymaster's own address because `getHash` commits to
///      both, so the test sets the chain id and places the paymaster at the vector's address. Nothing
///      here depends on deployment order.
contract SingletonPaymasterVectorTest is Test {
    string internal constant VECTOR_PATH = "test/Connect/vectors/singleton-paymaster.json";

    /// @dev `paymasterAndData` offsets of EntryPoint v0.7's `UserOperationLib`, plus the signed
    ///      prefix this paymaster hashes over: 52 + mode byte + `bytes6` validUntil + `bytes6`
    ///      validAfter. The signature follows it, so the two numbers are the same.
    uint256 internal constant PAYMASTER_DATA_OFFSET = 52;
    uint256 internal constant SIGNATURE_OFFSET = 65;

    SingletonPaymasterV7 internal paymaster;
    PackedUserOperation internal userOp;

    address internal paymasterAddress;
    address internal owner;
    address internal manager;
    address internal signer;
    uint256 internal signerKey;
    uint256 internal otherSignerKey;
    uint256 internal rotatedSignerKey;
    uint48 internal validUntil;
    uint48 internal validAfter;
    bytes32 internal expectedHash;
    bytes internal paymasterSignature;

    function setUp() public {
        string memory vector = vm.readFile(VECTOR_PATH);

        assertEq(vm.parseJsonUint(vector, ".schema"), 1, "unknown vector schema");
        assertEq(vm.parseJsonAddress(vector, ".entryPoint"), ENTRY_POINT_ADDRESS);
        assertEq(vm.parseJsonUint(vector, ".mode"), VERIFYING_MODE);
        assertTrue(vm.parseJsonBool(vector, ".allowAllBundlers"));
        assertTrue(vm.parseJsonBool(vector, ".eip191Prefixed"), "the contract prefixes getHash before recovery");

        vm.chainId(vm.parseJsonUint(vector, ".chainId"));
        vm.etch(ENTRY_POINT_ADDRESS, address(new EntryPoint()).code);

        paymasterAddress = vm.parseJsonAddress(vector, ".paymaster");
        owner = vm.parseJsonAddress(vector, ".owner");
        manager = vm.parseJsonAddress(vector, ".manager");
        signer = vm.parseJsonAddress(vector, ".signer");
        signerKey = vm.parseJsonUint(vector, ".signerKey");
        otherSignerKey = vm.parseJsonUint(vector, ".rotation.otherSignerKey");
        rotatedSignerKey = vm.parseJsonUint(vector, ".rotation.rotatedSignerKey");
        validUntil = uint48(vm.parseJsonUint(vector, ".validUntil"));
        validAfter = uint48(vm.parseJsonUint(vector, ".validAfter"));
        expectedHash = vm.parseJsonBytes32(vector, ".getHash");
        paymasterSignature = vm.parseJsonBytes(vector, ".paymasterSignature");

        assertEq(vm.addr(signerKey), signer, "signerKey and signer must be one pair");
        assertEq(vm.addr(otherSignerKey), vm.parseJsonAddress(vector, ".rotation.otherSigner"));
        assertEq(vm.addr(rotatedSignerKey), vm.parseJsonAddress(vector, ".rotation.rotatedSigner"));

        userOp = PackedUserOperation({
            sender: vm.parseJsonAddress(vector, ".userOp.sender"),
            nonce: vm.parseJsonUint(vector, ".userOp.nonce"),
            initCode: vm.parseJsonBytes(vector, ".userOp.initCode"),
            callData: vm.parseJsonBytes(vector, ".userOp.callData"),
            accountGasLimits: vm.parseJsonBytes32(vector, ".userOp.accountGasLimits"),
            preVerificationGas: vm.parseJsonUint(vector, ".userOp.preVerificationGas"),
            gasFees: vm.parseJsonBytes32(vector, ".userOp.gasFees"),
            paymasterAndData: vm.parseJsonBytes(vector, ".userOp.paymasterAndData"),
            signature: vm.parseJsonBytes(vector, ".userOp.signature")
        });

        // The vector's own packing, checked against the numbers it documents, so a hand-edit of one
        // side cannot pass unnoticed.
        assertEq(
            userOp.accountGasLimits,
            bytes32(
                (vm.parseJsonUint(vector, ".gasUnpacked.verificationGasLimit") << 128)
                    | vm.parseJsonUint(vector, ".gasUnpacked.callGasLimit")
            )
        );
        assertEq(
            userOp.gasFees,
            bytes32(
                (vm.parseJsonUint(vector, ".gasUnpacked.maxPriorityFeePerGas") << 128)
                    | vm.parseJsonUint(vector, ".gasUnpacked.maxFeePerGas")
            )
        );
        assertEq(vm.parseJsonUint(vector, ".signedPrefixLength"), SIGNATURE_OFFSET);

        // The paymaster must sit at the vector's address: getHash commits to `address(this)` through
        // the paymaster bytes of `paymasterAndData`, which it hashes over.
        address[] memory signers = new address[](1);
        signers[0] = signer;
        deployCodeTo(
            "SingletonPaymasterV7.sol:SingletonPaymasterV7",
            abi.encode(ENTRY_POINT_ADDRESS, owner, manager, signers),
            paymasterAddress
        );
        paymaster = SingletonPaymasterV7(paymasterAddress);
        assertTrue(paymaster.signers(signer));
    }

    function test_vector_paymasterAndDataCarriesTheDocumentedLayout() public view {
        assertEq(address(bytes20(_slice(userOp.paymasterAndData, 0, 20))), paymasterAddress);
        assertEq(uint128(bytes16(_slice(userOp.paymasterAndData, 20, 36))), 150000, "paymasterVerificationGasLimit");
        assertEq(uint128(bytes16(_slice(userOp.paymasterAndData, 36, 52))), 50000, "paymasterPostOpGasLimit");
        // Verifying mode (0) in the high bits, allowAllBundlers (1) in the lowest.
        assertEq(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET], bytes1(0x01));
        assertEq(uint48(bytes6(_slice(userOp.paymasterAndData, 53, 59))), validUntil);
        assertEq(uint48(bytes6(_slice(userOp.paymasterAndData, 59, 65))), validAfter);
        assertEq(_slice(userOp.paymasterAndData, SIGNATURE_OFFSET, userOp.paymasterAndData.length), paymasterSignature);
        assertEq(userOp.paymasterAndData.length, SIGNATURE_OFFSET + 65);
    }

    function test_vector_contractReproducesGetHash() public view {
        assertEq(paymaster.getHash(VERIFYING_MODE, userOp), expectedHash);
    }

    /// @dev The committed signature is reproducible from the committed key: FLU-1589's Go signer has
    ///      to match this byte for byte, so the vector may not drift from the contract.
    function test_vector_signatureIsTheSignersOverTheEip191Digest() public view {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, MessageHashUtils.toEthSignedMessageHash(expectedHash));
        assertEq(abi.encodePacked(r, s, v), paymasterSignature);
    }

    function test_validatePaymasterUserOp_acceptsTheSignersSignature() public {
        (bytes memory context, uint256 validationData) = _validate(userOp);

        // Verifying mode returns no context: postOp is never called, which is why ERC-7562 asks for
        // no stake here. The stake is kept by the user's decision, not by this contract's need.
        assertEq(context, "");
        assertFalse(_sigFailed(validationData));
        assertEq(_validUntilOf(validationData), validUntil);
        assertEq(_validAfterOf(validationData), validAfter);
    }

    function test_validatePaymasterUserOp_reportsAnotherKeysSignatureAsFailedWithoutReverting() public {
        assertTrue(vm.addr(otherSignerKey) != signer);

        // The call must return, not revert: a bundler needs the failure as validation data.
        (bytes memory context, uint256 validationData) = _validate(_signedBy(otherSignerKey));

        assertEq(context, "");
        assertTrue(_sigFailed(validationData));
        assertEq(_validUntilOf(validationData), validUntil);
        assertEq(_validAfterOf(validationData), validAfter);
    }

    /// @notice Signer rotation without a redeploy, the reason this contract replaces the
    ///         eth-infinitism sample whose `verifyingSigner` is immutable.
    function test_validatePaymasterUserOp_followsRemoveSignerAndAddSigner() public {
        address rotated = vm.addr(rotatedSignerKey);
        PackedUserOperation memory rotatedOp = _signedBy(rotatedSignerKey);

        // Before the rotation: the vector's signer is accepted, the new key is not.
        (, uint256 before_) = _validate(userOp);
        assertFalse(_sigFailed(before_));
        (, uint256 beforeRotated) = _validate(rotatedOp);
        assertTrue(_sigFailed(beforeRotated));

        vm.prank(owner);
        paymaster.removeSigner(signer);
        assertFalse(paymaster.signers(signer));

        vm.prank(owner);
        paymaster.addSigner(rotated);
        assertTrue(paymaster.signers(rotated));

        // After the rotation: the same bytes that passed now fail, and the new key passes. Nothing
        // was redeployed, so the address, the deposit and the stake are untouched.
        (, uint256 afterOld) = _validate(userOp);
        assertTrue(_sigFailed(afterOld));
        (, uint256 afterNew) = _validate(rotatedOp);
        assertFalse(_sigFailed(afterNew));
    }

    /// @dev Either role may rotate (`onlyAdminOrManager`), and nobody else may.
    function test_rotation_isRestrictedToTheOwnerAndTheManager() public {
        address rotated = vm.addr(rotatedSignerKey);

        vm.prank(manager);
        paymaster.addSigner(rotated);
        assertTrue(paymaster.signers(rotated));

        vm.prank(signer);
        vm.expectRevert();
        paymaster.addSigner(signer);
    }

    /// @notice One `UserOperationSponsored` per sponsored operation, another reason for this contract.
    function test_validatePaymasterUserOp_emitsUserOperationSponsored() public {
        bytes32 userOpHash = keccak256("flu-1590 user op hash");

        vm.expectEmit(true, true, true, true, paymasterAddress);
        emit UserOperationSponsored(userOpHash, userOp.sender, VERIFYING_MODE, address(0), 0, 0);

        vm.prank(ENTRY_POINT_ADDRESS);
        paymaster.validatePaymasterUserOp(userOp, userOpHash, 0);
    }

    event UserOperationSponsored(
        bytes32 indexed userOpHash,
        address indexed user,
        uint8 paymasterMode,
        address token,
        uint256 tokenAmountPaid,
        uint256 exchangeRate
    );

    function _validate(PackedUserOperation memory op) private returns (bytes memory context, uint256 validationData) {
        vm.prank(ENTRY_POINT_ADDRESS);
        return paymaster.validatePaymasterUserOp(op, bytes32(0), 0);
    }

    /// @dev The vector's operation with its paymaster signature replaced by `key`'s over the same
    ///      digest: everything `getHash` covers is the signed prefix, which this leaves untouched.
    function _signedBy(uint256 key) private view returns (PackedUserOperation memory op) {
        op = userOp;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, MessageHashUtils.toEthSignedMessageHash(expectedHash));
        op.paymasterAndData =
            abi.encodePacked(_slice(userOp.paymasterAndData, 0, SIGNATURE_OFFSET), abi.encodePacked(r, s, v));
    }

    /// @dev `Helpers.sol` packs the aggregator in the low 160 bits: `SIG_VALIDATION_FAILED` is 1.
    function _sigFailed(uint256 validationData) private pure returns (bool) {
        // SAFE: the aggregator is defined as the low 160 bits of the packed validation data.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 aggregator = uint160(validationData);
        assertTrue(aggregator <= 1, "this paymaster uses no aggregator");
        return aggregator == 1;
    }

    function _validUntilOf(uint256 validationData) private pure returns (uint48) {
        // SAFE: validUntil is defined as the 48 bits above the aggregator.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint48(validationData >> 160);
    }

    function _validAfterOf(uint256 validationData) private pure returns (uint48) {
        // SAFE: validAfter is defined as the top 48 bits of the packed validation data.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint48(validationData >> (160 + 48));
    }

    function _slice(bytes memory data, uint256 start, uint256 end) private pure returns (bytes memory out) {
        out = new bytes(end - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = data[start + i];
        }
    }
}
