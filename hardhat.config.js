require('@nomicfoundation/hardhat-toolbox'); // Toolbox for testing, debugging, and interacting with contracts
require('@nomicfoundation/hardhat-ignition');

module.exports = {
  defaultNetwork: 'hardhat',
  networks: {
    local: {
      url: 'http://127.0.0.1:8545', // Local network configuration for development
      accounts: {
        mnemonic: 'test test test test test test test test test test test junk',
        count: 10,
      },
      chainId: 1337, // Local network chain ID
    },
  },
  solidity: {
    version: '0.8.28',
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
};
