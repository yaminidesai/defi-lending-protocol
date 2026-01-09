const hre = require("hardhat");

async function main() {
  console.log("Starting deployment...\n");
  
  // Get deployer account
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  
  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", hre.ethers.formatEther(balance), "ETH\n");
  
  // Deploy PriceOracle
  console.log("Deploying PriceOracle...");
  const PriceOracle = await hre.ethers.getContractFactory("PriceOracle");
  const priceOracle = await PriceOracle.deploy();
  await priceOracle.waitForDeployment();
  const oracleAddress = await priceOracle.getAddress();
  console.log("✅ PriceOracle deployed to:", oracleAddress);
  
  // Deploy LendingPool
  console.log("\nDeploying LendingPool...");
  const LendingPool = await hre.ethers.getContractFactory("LendingPool");
  const lendingPool = await LendingPool.deploy(oracleAddress);
  await lendingPool.waitForDeployment();
  const poolAddress = await lendingPool.getAddress();
  console.log("✅ LendingPool deployed to:", poolAddress);
  
  // Verify oracle is set correctly
  const linkedOracle = await lendingPool.priceOracle();
  console.log("\n📊 Verification:");
  console.log("Oracle linked in LendingPool:", linkedOracle);
  console.log("Oracle address matches:", linkedOracle === oracleAddress ? "✅" : "❌");
  
  // Display protocol parameters
  console.log("\n⚙️  Protocol Parameters:");
  console.log("Collateral Factor:", (await lendingPool.COLLATERAL_FACTOR()).toString(), "basis points (75%)");
  console.log("Liquidation Threshold:", (await lendingPool.LIQUIDATION_THRESHOLD()).toString(), "basis points (80%)");
  console.log("Liquidation Bonus:", (await lendingPool.LIQUIDATION_BONUS()).toString(), "basis points (5%)");
  
  console.log("\n📋 Deployment Summary:");
  console.log("═══════════════════════════════════════");
  console.log("PriceOracle:  ", oracleAddress);
  console.log("LendingPool:  ", poolAddress);
  console.log("Network:      ", hre.network.name);
  console.log("Deployer:     ", deployer.address);
  console.log("═══════════════════════════════════════");
  
  console.log("\n✨ Deployment completed successfully!");
  
  // Return addresses for potential use in scripts
  return {
    priceOracle: oracleAddress,
    lendingPool: poolAddress,
    deployer: deployer.address
  };
}

// Execute deployment
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Deployment failed:");
    console.error(error);
    process.exit(1);
  });
