/** @type import('hardhat/config').HardhatUserConfig */
require("@nomiclabs/hardhat-ethers");
require("@nomiclabs/hardhat-solhint");
require("@openzeppelin/hardhat-upgrades");
require("hardhat-abi-exporter");
require("@nomicfoundation/hardhat-ignition-ethers");
require("@nomicfoundation/hardhat-foundry");

const { vars } = require("hardhat/config");

helpers = require("./helpers");

const accounts = process.env.PRIVATE_KEY
    ? [process.env.PRIVATE_KEY.startsWith("0x") ? process.env.PRIVATE_KEY : "0x" + process.env.PRIVATE_KEY]
    : ["1495992B2A5CC4DD53E231157BBF401329BD1B7EE355CEAB55A791398921CA17"];
const gasPrice = process.env.GAS_PRICE ? parseInt(process.env.GAS_PRICE) : "auto";

const HOLESKY_PRIVATE_KEY = vars.has("HOLESKY_PRIVATE_KEY") ? vars.get("HOLESKY_PRIVATE_KEY") : null;
const FLUENT_DEV_PRIVATE_KEY = process.env.FLUENT_DEV_PRIVATE_KEY || null;

module.exports = {
    solidity: {
        version: "0.8.30",
        settings: {
            optimizer: {
                enabled: true,
                runs: 200,
            },
        },
    },
    networks: {
        hardhat: {
            blockGasLimit: 300_000_000,
        },
        mainnet: {
            url: process.env.MAINNET_RPC || "https://rpc.ankr.com/eth",
            chainId: 1,
            gas: 8000000,
            gasPrice,
            accounts,
        },
        fluentTestnet: {
            url: process.env.RPC_URL_FLUENT_TESTNET || "https://rpc.testnet.fluent.xyz/",
            chainId: 20994,
            gas: 8000000,
            gasPrice,
            accounts,
        },
        sepoliaEth: {
            url: process.env.RPC_URL_SEPOLIA_ETH || "https://ethereum-sepolia-rpc.publicnode.com",
            chainId: 11155111,
            gas: 8000000,
            gasPrice,
            accounts,
        },
        fluentDev: {
            url: process.env.RPC_URL_FLUENT_DEV || "https://rpc.dev.fluent.xyz/",
            chainId: 20993,
            gas: 8000000,
            gasPrice,
            accounts,
        },
    },
    // Etherscan verification: https://docs.etherscan.io/contract-verification/verify-with-hardhat
    // Note: Etherscan API V2 (required as of Aug 2025) is fully supported in Hardhat 3 + @nomicfoundation/hardhat-verify 3.x (chainDescriptors, apiUrl: "https://api.etherscan.io/v2/api"). With Hardhat 2 + plugin 2.x, V1 endpoints are deprecated; use manual verification on sepolia.etherscan.io or upgrade to Hardhat 3 for scripted verify.
    etherscan: {
        apiKey: {
            sepolia: process.env.ETHERSCAN_API_KEY || "",
            sepoliaEth: process.env.ETHERSCAN_API_KEY || "",
        },
        // customChains: [
        //     {
        //         network: "sepoliaEth",
        //         chainId: 11155111,
        //         urls: {
        //             apiURL: "https://api-sepolia.etherscan.io/api",
        //             browserURL: "https://sepolia.etherscan.io",
        //         },
        //     },
        // ],
    },
    mocha: {
        timeout: 1000000, // Set the timeout to 60 seconds
    },
    abiExporter: {
        path: "./abi",
        clear: true,
        flat: true,
        spacing: 2,
    },
};
