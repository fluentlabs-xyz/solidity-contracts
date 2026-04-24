// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Airdrop} from "../../contracts/airdrop/Airdrop.sol";

// gblend script scripts/airdrop/DeployAirdrop.s.sol \
//  --rpc-url https://rpc.testnet.fluent.xyz \
//  --account sepolia-user

/// @notice One-shot airdrop runner: deploy + fund + distribute, all in one
///         broadcast. Edit the constants below, then run with --broadcast.
/// @dev    The broadcaster becomes the Airdrop owner and must hold enough
///         TOKEN (= TOTAL_TOKENS below) and native ETH (= recipients ×
///         ETH_PER_RECIPIENT + gas).
///
///         Recipients are inlined at compile time; JSON parsing was removed
///         because forge's parseJson + abi.decode is slow and fragile for
///         large (100+) arrays. Regenerate from recipients.json when the
///         list changes — see scripts/gen_deploy_airdrop.py.
contract DeployAirdrop is Script {
    // ─── Edit these ─────────────────────────────────────────────────────

    /// @dev ERC20 to distribute. On Fluent L2 this is typically a UST token.
    address constant TOKEN = 0x1385B8f55A84f2BdA13EeD4099d29Eae03d553b2;

    /// @dev Flat wei amount sent to every recipient on top of their token share.
    uint256 constant ETH_PER_RECIPIENT = 0.001 ether;

    /// @dev If true — skip the final distribute() call. Deploy and fund only,
    ///      then trigger distribute() manually when ready.
    bool constant SKIP_DISTRIBUTE = false;

    // ─── Derived / generated ────────────────────────────────────────────

    /// @dev Total recipient count. MUST match the length of the block built
    ///      in _buildEntries(). Checked at runtime with a require().
    uint256 constant RECIPIENT_COUNT = 146;

    /// @dev Sum of all tokenAmount values below. Precomputed so the deploy
    ///      logs it without a runtime loop; cross-checked against the array
    ///      in _verifyTotals() to catch copy-paste drift.
    uint256 constant TOTAL_TOKENS = 9271531832360000000000000;

    // ────────────────────────────────────────────────────────────────────

    function run() external returns (address airdropAddr) {
        (address[] memory recipients, uint96[] memory amounts) = _buildEntries();
        _verifyTotals(amounts);

        uint256 totalEth = RECIPIENT_COUNT * ETH_PER_RECIPIENT;

        console2.log("=== DeployAirdrop ===");
        console2.log("  token:                  ", TOKEN);
        console2.log("  recipients:             ", RECIPIENT_COUNT);
        console2.log("  ethPerRecipient (finney):", ETH_PER_RECIPIENT / 0.001 ether);
        console2.log("  totalTokens (WEI):            ", TOTAL_TOKENS);
        console2.log("  totalTokens:            ", TOTAL_TOKENS / 1 ether);
        console2.log("  totalEth (finney):      ", totalEth / 0.001 ether);
        console2.log("  skipDistribute:         ", SKIP_DISTRIBUTE);

        // Broadcast account becomes the Airdrop owner, which is why the same
        // block can call distribute() at the end.
        vm.startBroadcast();

        console2.log(msg.sender);

        Airdrop airdrop = new Airdrop(IERC20(TOKEN), ETH_PER_RECIPIENT, recipients, amounts);
        airdropAddr = address(airdrop);

        // Plain ERC20 transfer — no approve, no custom deposit.
        IERC20(TOKEN).transfer(airdropAddr, TOTAL_TOKENS);

        // `receive()` on the Airdrop accepts it silently.
        (bool ok, ) = airdropAddr.call{value: totalEth}("");
        require(ok, "eth funding failed");

        if (!SKIP_DISTRIBUTE) {
            airdrop.distribute();
        }

        vm.stopBroadcast();

        console2.log("Airdrop deployed:", airdropAddr);
        if (!SKIP_DISTRIBUTE) console2.log("Distributed.");
    }

    /// @dev Cross-checks that the inlined amounts sum to the constant
    ///      TOTAL_TOKENS. Catches the classic "edit one row, forget to
    ///      update the total" bug before we commit funds on-chain.
    function _verifyTotals(uint96[] memory amounts) internal pure {
        uint256 sum;
        for (uint256 i = 0; i < amounts.length; ++i) sum += amounts[i];
        require(sum == TOTAL_TOKENS, "DeployAirdrop: TOTAL_TOKENS out of sync with array");
    }

    /// @dev Returns the inlined recipients and matching tokenAmounts.
    ///      Ordering follows recipients.json (descending by tokenAmount).
    ///      Regenerate from JSON — do NOT hand-edit individual rows.
    function _buildEntries() internal pure returns (address[] memory recipients, uint96[] memory amounts) {
        recipients = new address[](RECIPIENT_COUNT);
        amounts = new uint96[](RECIPIENT_COUNT);

        recipients[0] = 0x0a8E4402523E29EF0EE61f8B7cA774805b4843E6;
        amounts[0] = 1690410000000000000000000;
        recipients[1] = 0xecF9AF20266cB37D7842880CAB5ccf46D4b0195c;
        amounts[1] = 1690410000000000000000000;
        recipients[2] = 0x220b522979B9F2Ca0F83663fcfF2ee2426aa449C;
        amounts[2] = 818000000000000000000000;
        recipients[3] = 0x58b80FF10946cFdA425c81F8619c6C1615A517B5;
        amounts[3] = 591644305050000000000000;
        recipients[4] = 0xE1D5B5D299d0A2209B2DF23e49ebf654606bACa8;
        amounts[4] = 570000000000000000000000;
        recipients[5] = 0x61BE15e044725889f2f361447C41F4Ab02972967;
        amounts[5] = 500000000000000000000000;
        recipients[6] = 0xbf81fd0138bC37ad2B4dA9eb26A365Bd0db70Ef8;
        amounts[6] = 476000000000000000000000;
        recipients[7] = 0x3F043c80696fc46e5a3FbfD1cf86dcbbA5fcc62C;
        amounts[7] = 475000000000000000000000;
        recipients[8] = 0xa4B2B1fDd2C1B072202f16E812B46EdE09f526f4;
        amounts[8] = 400000000000000000000000;
        recipients[9] = 0x476D3F4Ad96A6091aac616c3458d50f1e3f4DBCB;
        amounts[9] = 350000000000000000000000;
        recipients[10] = 0x970f81A9c65F2A13bA45E51E11564c12610d32C4;
        amounts[10] = 300000000000000000000000;
        recipients[11] = 0xb2605b8534801772570A9B8f323Dd41d83349aFE;
        amounts[11] = 300000000000000000000000;
        recipients[12] = 0x8Dd42D11bf804c497B1a10c8EA47d8943005d045;
        amounts[12] = 200000000000000000000000;
        recipients[13] = 0xc9D9a18Be45965245193d8F0A1c2A6BB61905cb4;
        amounts[13] = 190000000000000000000000;
        recipients[14] = 0x75E54ACb9107Cc35969b44Eb6342F50686b3A12d;
        amounts[14] = 80294584260000000000000;
        recipients[15] = 0x2F3B842Ec7fD86E483A261a637e03e25dc96e3dF;
        amounts[15] = 63390461260000000000000;
        recipients[16] = 0x54f14F4242Df01Aa2846606C5B68F29cFee1e11c;
        amounts[16] = 42260307500000000000000;
        recipients[17] = 0x20BA204959Be0bAb7eF8C9046d4780b7aDFea3AC;
        amounts[17] = 38034276750000000000000;
        recipients[18] = 0xDEcdd88AB5e9593a8C915243c8D5b6Ef4070C133;
        amounts[18] = 35498658300000000000000;
        recipients[19] = 0x9d9dCF4f14916AF59f3fDb7F1e19f3dFDe6BbB7a;
        amounts[19] = 33808246000000000000000;
        recipients[20] = 0x87153C509cb9e7Da3b1C61912D06366dd04bFE71;
        amounts[20] = 26725418470000000000000;
        recipients[21] = 0xD6bA4482f7f27A8F75247d9bC4DDe8B4b165707B;
        amounts[21] = 25787239640000000000000;
        recipients[22] = 0x631422FF12fef7435f3f71D8168e614A0740D821;
        amounts[22] = 21975359900000000000000;
        recipients[23] = 0xbF17D39a8D4a13C9A6A9E0AE9B97ed3f71189CAA;
        amounts[23] = 21857031040000000000000;
        recipients[24] = 0xc1E7CA17274C36a3358460F93ce30200916688b6;
        amounts[24] = 21130153750000000000000;
        recipients[25] = 0x31E3fA1A110d2bfcE3F96f05c18d76B029f6B89F;
        amounts[25] = 17833849770000000000000;
        recipients[26] = 0x1F3AB7468F3e51646B3AebBA26c6fb6302A02d55;
        amounts[26] = 16904123000000000000000;
        recipients[27] = 0x2F2F665974261C4129b1DC6c359BD259CD66f78A;
        amounts[27] = 16904123000000000000000;
        recipients[28] = 0x1D433a6b9e1D4c9371447115B34d92Cdb50F55CD;
        amounts[28] = 13261284490000000000000;
        recipients[29] = 0xdC4EfDac43475F434482e61805E0df96D2dC1DF4;
        amounts[29] = 12678092250000000000000;
        recipients[30] = 0x8bf7865dE9C806A1a63F66d3A421024E3CC5878a;
        amounts[30] = 10624241310000000000000;
        recipients[31] = 0x06fe6D22EE588bA88C2349FA7d9Ad3149C0c57a3;
        amounts[31] = 10142473800000000000000;
        recipients[32] = 0x627215918F7cf0d2805465cb94ebC951e9750aE9;
        amounts[32] = 8452061500000000000000;
        recipients[33] = 0x90e06d2d9705c181Bad2A4e7c3DcA13631a6f479;
        amounts[33] = 8452061500000000000000;
        recipients[34] = 0xB2F9BbC5db84a95B598cAB0C464cF92D584d8900;
        amounts[34] = 8452061500000000000000;
        recipients[35] = 0xb5BF7aF48409dB9C4761c27409C1e283463aB8B6;
        amounts[35] = 8452061500000000000000;
        recipients[36] = 0xA55e98D3F9fB8D09450522BD1a5A02e8f0F5E885;
        amounts[36] = 8113979040000000000000;
        recipients[37] = 0x1E9D987188F712084CcF924C31102E15175528CE;
        amounts[37] = 7632211540000000000000;
        recipients[38] = 0xC29240c96F096C4D4C5DDd11533DfdE66338f0D7;
        amounts[38] = 6773397570000000000000;
        recipients[39] = 0x330198F0FB0A0881958D3095E0cBDC4Bc3DCe22c;
        amounts[39] = 5916443050000000000000;
        recipients[40] = 0xDBA34a99D3eD1352d9e7BD1649F971AA42b873fF;
        amounts[40] = 5916443050000000000000;
        recipients[41] = 0xf4e7E6B600286fFba8154F5125420A0F78DB835d;
        amounts[41] = 5071236900000000000000;
        recipients[42] = 0x02819Ba4A9C15D0366aC2e896f1A442db420e2Da;
        amounts[42] = 4234482810000000000000;
        recipients[43] = 0x47CDDFBc26Da2dF3b10F360b32c52A33e309023d;
        amounts[43] = 4226030750000000000000;
        recipients[44] = 0xA5d2515Ce6841253e886105E4158990F91D32182;
        amounts[44] = 4226030750000000000000;
        recipients[45] = 0xB625a2a5847368bBe0b719425b6eDC12f8ccAd58;
        amounts[45] = 4226030750000000000000;
        recipients[46] = 0xd4FDB03e6e2f44B8739209586016625cdED46475;
        amounts[46] = 4226030750000000000000;
        recipients[47] = 0x29eD22DE5471Ff565F57f9725f0cB62135fAA25a;
        amounts[47] = 4221804720000000000000;
        recipients[48] = 0xA80c6c2e9974b930c81633cA1103ef350054410F;
        amounts[48] = 3955564780000000000000;
        recipients[49] = 0x11fdF483eCB71a7b3B036df9158ED5af2D696eAD;
        amounts[49] = 3921756540000000000000;
        recipients[50] = 0x115dB9A94996d8d653c8faA1356bb2E5Aa533348;
        amounts[50] = 3380824600000000000000;
        recipients[51] = 0x01514e6b79145c7e0fa796b37DccaFa808731Ec5;
        amounts[51] = 2535618450000000000000;
        recipients[52] = 0x1C2238094acE6076A1267c8492C9efd00E2dDaaF;
        amounts[52] = 2535618450000000000000;
        recipients[53] = 0x80E0790A59643B8DAd913719b0f9C78EcE673dD2;
        amounts[53] = 2535618450000000000000;
        recipients[54] = 0xeeE072349A531CbD66BA9fD1a6d55197a1Fc022b;
        amounts[54] = 2527166390000000000000;
        recipients[55] = 0x8c516fa4BA6d562E0a835Cc3dD4F35f97D277B8f;
        amounts[55] = 2263132440000000000000;
        recipients[56] = 0x0b7E5CB8AF3321a340075a4d69C001fb8F4a5c6e;
        amounts[56] = 2113015380000000000000;
        recipients[57] = 0xe0FDaA90dEBd226DBB5D56E8D30a9C75afecCA4C;
        amounts[57] = 2003138580000000000000;
        recipients[58] = 0xFe6E24b7109d19CD9a7411dDB99Ef3A31d08b9f9;
        amounts[58] = 1774932920000000000000;
        recipients[59] = 0xe058f0f377beebd0E2243BcaAF3F69bbfbcbE0FC;
        amounts[59] = 1754647970000000000000;
        recipients[60] = 0x354a4Ea3f7C655fCD6C83319F20669E0d72b3ac0;
        amounts[60] = 1732672610000000000000;
        recipients[61] = 0xe652D940475aCD9B16628CB386722224f49d0B9F;
        amounts[61] = 1692609840000000000000;
        recipients[62] = 0x59073Fad69801eDD095B501267Fd67269d11f683;
        amounts[62] = 1692102710000000000000;
        recipients[63] = 0xAFABa879575d93f3DdB187321cfE8615D47F9bA1;
        amounts[63] = 1690412300000000000000;
        recipients[64] = 0xaf0B581c9bD693DeCC6D9e7beb4bf8D619f90E5d;
        amounts[64] = 1551756230000000000000;
        recipients[65] = 0xAE01a9f15b278239CFb64D4D74bBA7a0b1cF900D;
        amounts[65] = 1310154050000000000000;
        recipients[66] = 0x80E2dB20022F9a4c372897F97C09dbCb74C12820;
        amounts[66] = 1308810180000000000000;
        recipients[67] = 0x4D196e2f19F28c2D940ce382DD3AC5D25c72d75D;
        amounts[67] = 1267809230000000000000;
        recipients[68] = 0x25F67793A1BFb1Bc2dC7acb1b8793f078d939354;
        amounts[68] = 1259357160000000000000;
        recipients[69] = 0xf96Ddaa24D9f01D30443D5E95dbEe0E79aFC59D3;
        amounts[69] = 1259357160000000000000;
        recipients[70] = 0xA1f64448B98C7c646693A7B86642beBB214ad784;
        amounts[70] = 1014247380000000000000;
        recipients[71] = 0x9238317cAbC824714D6251a13BdB430969Ce039F;
        amounts[71] = 1005795320000000000000;
        recipients[72] = 0x7E6c03B4B10FD8a1f0F4a8FD4EBFe8e51Ce3FB19;
        amounts[72] = 980439130000000000000;
        recipients[73] = 0xbfd856CBD379BFB5970878787aDe45Bc6a73AeFF;
        amounts[73] = 971987070000000000000;
        recipients[74] = 0x9a030d12BdF8E35c0922f68d48BCc5DF1Ce649A5;
        amounts[74] = 946630890000000000000;
        recipients[75] = 0xC7F92c993913FD9b31B8e6bf4298f4eDFA58da1A;
        amounts[75] = 946630890000000000000;
        recipients[76] = 0x3Ad5Bbe0b972198660F75913c14E5FD923551268;
        amounts[76] = 938178830000000000000;
        recipients[77] = 0x705dD9773685CdFdFf8a18896a0DC29D30cFf8b1;
        amounts[77] = 921274700000000000000;
        recipients[78] = 0xE56E01848565c3D133C6cFF168E674CAAD0d0CB6;
        amounts[78] = 921274700000000000000;
        recipients[79] = 0xF2397b7789098DbB3D20Ae3Eb4c8E6247696b824;
        amounts[79] = 921274700000000000000;
        recipients[80] = 0xDD15901d868dAC0601899dBcD829cd28539faB1F;
        amounts[80] = 914513050000000000000;
        recipients[81] = 0x24D9c0d0D5dF8a0c6dc4F159Fc12d7fACC980f5E;
        amounts[81] = 912822640000000000000;
        recipients[82] = 0xafe40fb9AE6baa931A1F5A2e5aEC38824A2174a0;
        amounts[82] = 904370580000000000000;
        recipients[83] = 0xb76Eb96077d14B2fCC0b8321911FC2EB43e271b9;
        amounts[83] = 896980100000000000000;
        recipients[84] = 0x9C952fc22AD42A56A7399fEB9879b0E696099798;
        amounts[84] = 887466460000000000000;
        recipients[85] = 0xa132fBe5D77F3F5F8A70FFE75d186Ec0551c90ea;
        amounts[85] = 887466460000000000000;
        recipients[86] = 0xaa81C9945aF40d102bb337eC03ed7b9FEe4355fb;
        amounts[86] = 887466460000000000000;
        recipients[87] = 0xaF39243d70942432b104219488999Ab76AF312C7;
        amounts[87] = 887466460000000000000;
        recipients[88] = 0xBA095AE8A0E97db1bb50615909De81C734F18831;
        amounts[88] = 887466460000000000000;
        recipients[89] = 0xd4f47C4e74F755acf3825338aE8A029090eB7f76;
        amounts[89] = 887466460000000000000;
        recipients[90] = 0x9F731b3B527BC5644943e251DA4f7B5F3A9C0f79;
        amounts[90] = 879014400000000000000;
        recipients[91] = 0x02D7D509F5129C1a727E74d6b6E6cB57a83Fe78C;
        amounts[91] = 875549050000000000000;
        recipients[92] = 0xb93FCfD1aA6148CeBa3471AE0d7D0A43c9C3E54a;
        amounts[92] = 873351510000000000000;
        recipients[93] = 0xf2AEB87d080a74ff64F3DC0E4Ac6959bda1b752F;
        amounts[93] = 873266990000000000000;
        recipients[94] = 0x89DeC97F238A983341224A52A74fc6D7263BDD67;
        amounts[94] = 870562330000000000000;
        recipients[95] = 0x997ad5Aa9eAF92318C37fcfec63d1dE9D6b161B2;
        amounts[95] = 870562330000000000000;
        recipients[96] = 0xF77FAEA0E2EED79B7b655C739Aa05B8D671713d7;
        amounts[96] = 870562330000000000000;
        recipients[97] = 0x9612948DDa9d8A62736e1D234cF86Cf76096e0c0;
        amounts[97] = 866674390000000000000;
        recipients[98] = 0x372B2Fabf396B4624be5177Ac48361DB931D793d;
        amounts[98] = 863175230000000000000;
        recipients[99] = 0x4f2ce4565b48E0189072Dd2eD0Aa062375eD59Cf;
        amounts[99] = 862955480000000000000;
        recipients[100] = 0xB7206C6CAb589365F80e3BBd3Beb5BA13D43e274;
        amounts[100] = 862110270000000000000;
        recipients[101] = 0xEaa4CFFf07c6cECeb9daB63b9909DB37e1a56574;
        amounts[101] = 862110270000000000000;
        recipients[102] = 0xfd9DdC9C238Ef57b574436D9308E19d2377E8a84;
        amounts[102] = 862110270000000000000;
        recipients[103] = 0x543B39a5CB2885959fc89E5f73088153756976cd;
        amounts[103] = 858281490000000000000;
        recipients[104] = 0x59A9F768D7aa7D3245FE2096290D7bEebAa8aC02;
        amounts[104] = 855348620000000000000;
        recipients[105] = 0x99F846dF5d95aBa065b5c8f6b8A4b7e0817bac68;
        amounts[105] = 854503420000000000000;
        recipients[106] = 0x073587790AE03769e38F221cE27475D213cc1CB6;
        amounts[106] = 853658210000000000000;
        recipients[107] = 0x10ab5e23a1849d6eDBEDF10E9E5a1eD3069560Bf;
        amounts[107] = 853658210000000000000;
        recipients[108] = 0x177B1e833d67A07Ee65458C7Ee8cbFe820C3D05C;
        amounts[108] = 853658210000000000000;
        recipients[109] = 0x3a0D440A4D3F7BA210132ca5a46aa67C75631E17;
        amounts[109] = 853658210000000000000;
        recipients[110] = 0x43b755D01042b430F3DE3Ad5aa1112be3fbFE9d4;
        amounts[110] = 853658210000000000000;
        recipients[111] = 0x7fE348c4bbdFc3B01AD70F4bf19aC8D690114891;
        amounts[111] = 853658210000000000000;
        recipients[112] = 0x8466D82A7c514680864bF4cb5d091e777B40f4D0;
        amounts[112] = 853658210000000000000;
        recipients[113] = 0xa8E9221AFaab3105A6105476638199dE2E09690B;
        amounts[113] = 853658210000000000000;
        recipients[114] = 0xc28F1087022215B15A3a202A4129792f88e9E5fa;
        amounts[114] = 853658210000000000000;
        recipients[115] = 0xcf8d46bcC38EE33370b278133367b100797D2375;
        amounts[115] = 853658210000000000000;
        recipients[116] = 0xd6D024b365F8eF4F57B2fde03324b3E0d52AD8a3;
        amounts[116] = 849854780000000000000;
        recipients[117] = 0x14CA0bE44d0C6955d41Da3FDDA60572Db7E672Ee;
        amounts[117] = 849432180000000000000;
        recipients[118] = 0x8CF7F35e11964173527d4585AC4B9d529526EFd4;
        amounts[118] = 849432180000000000000;
        recipients[119] = 0xdA54E9d978ab8f245b688cD340e49FD86A366aa4;
        amounts[119] = 849432180000000000000;
        recipients[120] = 0x0c6B255395bc04913BA663dDD4E87703efde764B;
        amounts[120] = 848688400000000000000;
        recipients[121] = 0x9F0Bf9a095c7D29d4a99cA19fD71B0e4e9fd87E0;
        amounts[121] = 846896560000000000000;
        recipients[122] = 0xe697B1ef5C2C36d323eFe152dE02cb348306f1F4;
        amounts[122] = 846896560000000000000;
        recipients[123] = 0x84BAe0D2d1DB0028D5bc6dA98382dF4EE1b0b0a0;
        amounts[123] = 846051360000000000000;
        recipients[124] = 0x0ab02e784Bd2917C457BE1c354D138A2cE6088f0;
        amounts[124] = 845206150000000000000;
        recipients[125] = 0x10DF38d464Ee4C99756C5972e333f626F7c1eD99;
        amounts[125] = 845206150000000000000;
        recipients[126] = 0x36BCad3a6e12c5fd5371853e861Ffd044F835adF;
        amounts[126] = 845206150000000000000;
        recipients[127] = 0x3bf965641AdcE4321CcC50e0b548ACF44a7983A0;
        amounts[127] = 845206150000000000000;
        recipients[128] = 0x4024c5268359f091F57B735889fCbB4d930944Dc;
        amounts[128] = 845206150000000000000;
        recipients[129] = 0x4AFC6fAFbe1cd2B4c074107b86d2FB95C4c76abF;
        amounts[129] = 845206150000000000000;
        recipients[130] = 0x561295F5D39036903Dacf7B2e9Aac8bD3BE1bAE5;
        amounts[130] = 845206150000000000000;
        recipients[131] = 0x58de82939fDa9E3Ab3769E67dd78DcCe03e1BF17;
        amounts[131] = 845206150000000000000;
        recipients[132] = 0x6Cb596C5b8f09B4bD1c534fbfb9389D1b5cB6986;
        amounts[132] = 845206150000000000000;
        recipients[133] = 0x71F14e13EdB8Fa226c93F5C6E1EC8796168b8F34;
        amounts[133] = 845206150000000000000;
        recipients[134] = 0x73912644e5111fbDBc63FB4562c3B786f624F0F5;
        amounts[134] = 845206150000000000000;
        recipients[135] = 0x7ee68b1ca335574DBDB80c0e24ac6419f0e67B03;
        amounts[135] = 845206150000000000000;
        recipients[136] = 0x81640F98b8Af7804995EB4Fd3A15e72c44ad644d;
        amounts[136] = 845206150000000000000;
        recipients[137] = 0x828E32e629B887Dd4bbF388e4b42D8392023102B;
        amounts[137] = 845206150000000000000;
        recipients[138] = 0x9c1c17707cB5EDaFF9A0e6BFA444023Ce479De8a;
        amounts[138] = 845206150000000000000;
        recipients[139] = 0xB96868bA162b51CF9C8DFB69Bf5b9682B4C6B23b;
        amounts[139] = 845206150000000000000;
        recipients[140] = 0xB968DCaD041665faFA8289177330300C01c0ccf9;
        amounts[140] = 845206150000000000000;
        recipients[141] = 0xC52A0444315dab7e10ec90E3D543a919a3949cC0;
        amounts[141] = 845206150000000000000;
        recipients[142] = 0xD5457933266b2355DF599ed52cD383b27af70140;
        amounts[142] = 845206150000000000000;
        recipients[143] = 0xe498e919dc961700c8d0F4a507344467A49609fa;
        amounts[143] = 845206150000000000000;
        recipients[144] = 0xF8FE281a44dEF550c620882364E4A00F2EA80218;
        amounts[144] = 845206150000000000000;
        recipients[145] = 0xfa19f5593b9B4Ce148b4A08901BBb7b884e7f326;
        amounts[145] = 845206150000000000000;
    }
}
