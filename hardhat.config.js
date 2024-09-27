require("@nomicfoundation/hardhat-toolbox");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 500  // Set a lower number of runs to further optimize for code size
      }
    }
  },
  networks: {
    sepolia: {
      url: "https://ethereum-sepolia-rpc.publicnode.com", // Replace with Infura/Alchemy URL
      accounts: [], // Replace with your wallet private key
    },
    polygon_amoy: {
      url: "https://polygon-amoy.drpc.org",
      accounts: []
    },
    polygon: {
      url: "https://polygon-rpc.com",
      accounts: []
    }
  },
  etherscan: {
    apiKey: {
      sepolia: "", // Replace with your Etherscan API key
      polygon: "",
    },
  },
};