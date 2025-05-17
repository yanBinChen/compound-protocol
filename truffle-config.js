module.exports = {
  networks: {
    development: {
      host: "127.0.0.1",
      port: 7545, // Ganache CLI 默认端口（UI 用 7545）
      network_id: "*",
      gas: 6721975,
      gasPrice: 20000000000
    }
  },
  compilers: {
    solc: {
      version: "0.8.10", // 更新为 0.8.10
      settings: {
        optimizer: {
          enabled: true,
          runs: 200
        }
      }
    }
  },
  contracts_directory: "./contracts",
  contracts_build_directory: "./build/contracts",
  migrations_directory: "./migrations"
};