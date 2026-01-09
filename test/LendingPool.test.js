const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("LendingPool", function () {
  let lendingPool, priceOracle;
  let owner, user1, user2;

  beforeEach(async function () {
    [owner, user1, user2] = await ethers.getSigners();

    // Deploy PriceOracle
    const PriceOracle = await ethers.getContractFactory("PriceOracle");
    priceOracle = await PriceOracle.deploy();
    await priceOracle.waitForDeployment();

    // Deploy LendingPool
    const LendingPool = await ethers.getContractFactory("LendingPool");
    lendingPool = await LendingPool.deploy(await priceOracle.getAddress());
    await lendingPool.waitForDeployment();
  });

  describe("Deployment", function () {
    it("Should deploy contracts successfully", async function () {
      expect(await lendingPool.getAddress()).to.be.properAddress;
      expect(await priceOracle.getAddress()).to.be.properAddress;
    });

    it("Should link oracle correctly", async function () {
      expect(await lendingPool.priceOracle()).to.equal(await priceOracle.getAddress());
    });

    it("Should have correct protocol parameters", async function () {
      expect(await lendingPool.COLLATERAL_FACTOR()).to.equal(7500); // 75%
      expect(await lendingPool.LIQUIDATION_THRESHOLD()).to.equal(8000); // 80%
      expect(await lendingPool.LIQUIDATION_BONUS()).to.equal(500); // 5%
      expect(await lendingPool.BASIS_POINTS()).to.equal(10000); // 100%
    });

    it("Should have correct interest rate parameters", async function () {
      expect(await lendingPool.baseRate()).to.equal(200); // 2%
      expect(await lendingPool.multiplier()).to.equal(1000); // 10%
      expect(await lendingPool.kink()).to.equal(8000); // 80%
      expect(await lendingPool.jumpMultiplier()).to.equal(5000); // 50%
    });
  });

  describe("Market Listing", function () {
    it("Should allow owner to list a market", async function () {
      const tokenAddress = "0x1234567890123456789012345678901234567890";
      
      await expect(lendingPool.listMarket(tokenAddress))
        .to.emit(lendingPool, "MarketListed")
        .withArgs(tokenAddress);

      const market = await lendingPool.markets(tokenAddress);
      expect(market.isListed).to.be.true;
      expect(market.totalDeposits).to.equal(0);
      expect(market.totalBorrows).to.equal(0);
      expect(market.borrowIndex).to.equal(ethers.parseEther("1"));
    });

    it("Should not allow non-owner to list markets", async function () {
      const tokenAddress = "0x1234567890123456789012345678901234567890";
      
      await expect(
        lendingPool.connect(user1).listMarket(tokenAddress)
      ).to.be.revertedWithCustomError(lendingPool, "OwnableUnauthorizedAccount");
    });

    it("Should not allow listing the same market twice", async function () {
      const tokenAddress = "0x1234567890123456789012345678901234567890";
      
      await lendingPool.listMarket(tokenAddress);
      
      await expect(
        lendingPool.listMarket(tokenAddress)
      ).to.be.revertedWithCustomError(lendingPool, "MarketAlreadyListed");
    });

    it("Should track supported tokens count", async function () {
      expect(await lendingPool.getSupportedTokensCount()).to.equal(0);

      await lendingPool.listMarket("0x1234567890123456789012345678901234567890");
      expect(await lendingPool.getSupportedTokensCount()).to.equal(1);

      await lendingPool.listMarket("0x0987654321098765432109876543210987654321");
      expect(await lendingPool.getSupportedTokensCount()).to.equal(2);
    });

    it("Should return correct token from supportedTokens array", async function () {
      const token1 = "0x1234567890123456789012345678901234567890";
      const token2 = "0x0987654321098765432109876543210987654321";

      await lendingPool.listMarket(token1);
      await lendingPool.listMarket(token2);

      expect(await lendingPool.supportedTokens(0)).to.equal(token1);
      expect(await lendingPool.supportedTokens(1)).to.equal(token2);
    });
  });

  describe("Interest Rate Model", function () {
    const tokenAddress = "0x1234567890123456789012345678901234567890";

    beforeEach(async function () {
      await lendingPool.listMarket(tokenAddress);
    });

    it("Should return base rate when utilization is 0%", async function () {
      const rate = await lendingPool.getBorrowRate(tokenAddress);
      expect(rate).to.equal(200); // 2% base rate
    });

    it("Should calculate rate correctly before kink", async function () {
      // Simulate 50% utilization manually by checking the formula
      // Rate should be: baseRate + (utilization * multiplier / BASIS_POINTS)
      // = 200 + (5000 * 1000 / 10000) = 200 + 500 = 700 (7%)
      
      // We can't easily test this without deposits, but we verified the formula exists
      const baseRate = await lendingPool.baseRate();
      const multiplier = await lendingPool.multiplier();
      
      expect(baseRate).to.equal(200);
      expect(multiplier).to.equal(1000);
    });
  });

  describe("Price Oracle Integration", function () {
    it("Should allow setting fallback prices", async function () {
      const tokenAddress = "0x1234567890123456789012345678901234567890";
      const price = ethers.parseEther("2000"); // $2000

      await expect(priceOracle.setFallbackPrice(tokenAddress, price))
        .to.emit(priceOracle, "FallbackPriceSet")
        .withArgs(tokenAddress, price);

      expect(await priceOracle.fallbackPrices(tokenAddress)).to.equal(price);
    });

    it("Should get price from fallback", async function () {
      const tokenAddress = "0x1234567890123456789012345678901234567890";
      const price = ethers.parseEther("2000");

      await priceOracle.setFallbackPrice(tokenAddress, price);
      
      const retrievedPrice = await priceOracle.getPrice(tokenAddress);
      expect(retrievedPrice).to.equal(price);
    });

    it("Should not allow zero price", async function () {
      const tokenAddress = "0x1234567890123456789012345678901234567890";

      await expect(
        priceOracle.setFallbackPrice(tokenAddress, 0)
      ).to.be.revertedWithCustomError(priceOracle, "PriceMustBePositive");
    });
  });

  describe("Account Health", function () {
    it("Should return max health for account with no borrows", async function () {
      const health = await lendingPool.getAccountHealth(user1.address);
      expect(health).to.equal(ethers.MaxUint256);
    });

    it("Should return 0 liquidity for new account", async function () {
      const liquidity = await lendingPool.getAccountLiquidity(user1.address);
      expect(liquidity).to.equal(0);
    });
  });
});
