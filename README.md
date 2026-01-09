# DeFi Lending Protocol

> A collateralized lending platform implementing industry-standard DeFi primitives with dynamic interest rates and automated liquidations.

## Overview

This project implements a functional lending protocol similar to Aave or Compound, featuring over-collateralized borrowing, dynamic interest rate models, and automated liquidation mechanisms. Built as a portfolio piece to demonstrate practical knowledge of DeFi architecture patterns and Solidity best practices.

**⚠️ Disclaimer:** This is a demonstration project for learning purposes. It has not undergone professional security audits and should not be deployed to mainnet with real funds.

## Motivation

After studying existing DeFi protocols, I wanted to understand the mechanics by building one from scratch. This project challenged me to think through:
- Precise financial calculations in Solidity without floating-point arithmetic
- Managing complex state across multiple users and token markets
- Implementing time-based interest accrual efficiently
- Designing secure liquidation mechanics that protect both lenders and borrowers
- Integrating external price feeds with proper error handling

The result is approximately 800 lines of production-quality Solidity code.

## Key Features

### Core Functionality
- **Collateralized Lending**: Deposit assets and borrow against them (75% LTV)
- **Dynamic Interest Rates**: Kinked model responding to utilization (2-52% APY)
- **Automated Liquidations**: Protect protocol solvency with 5% liquidator incentive
- **Multi-Token Support**: Add any ERC20 token as a market
- **Real-Time Pricing**: Chainlink oracle integration with staleness checks

### Technical Highlights
- **Gas Optimizations**: Custom errors, constants, unchecked math where safe
- **Security Patterns**: ReentrancyGuard, SafeERC20, access control
- **Continuous Compounding**: Efficient index-based interest accrual
- **Health Monitoring**: Real-time liquidation risk calculation

## Architecture

### Smart Contracts

**LendingPool.sol** (500+ LOC)
- Core lending and borrowing logic
- Interest rate calculations using kinked model
- Liquidation engine
- Account health tracking

**PriceOracle.sol** (100 LOC)
- Chainlink price feed integration
- Fallback pricing mechanism
- Staleness validation (1-hour threshold)
- 18-decimal normalization

**IPriceOracle.sol**
- Standard oracle interface

## How It Works

### Interest Rate Model
```
if utilization <= 80%:
    rate = 2% + (utilization × 10%)
else:
    rate = 2% + (80% × 10%) + ((utilization - 80%) × 50%)
```

This creates two slopes:
- **0-80% utilization**: Gentle increase (2-10% APY)
- **80-100% utilization**: Steep jump (10-52% APY)

The kink protects lender liquidity during high demand.

### Liquidation Mechanics

When collateral value falls below 80% of debt value:
1. Anyone can liquidate up to 50% of the debt
2. Liquidator repays borrowed tokens
3. Receives equivalent collateral + 5% bonus
4. Borrower retains remaining position

The 5% bonus incentivizes quick liquidations while being conservative enough to avoid unnecessary liquidations of marginally underwater positions.

### Interest Accrual

Interest compounds continuously using:
```
newIndex = oldIndex × (1 + rate × timeElapsed / secondsPerYear)
```

Each user's debt scales by the market's borrow index, so interest accrues automatically without per-user storage updates. This pattern scales to thousands of users efficiently.

## Getting Started

### Prerequisites
- Node.js v16+
- npm or yarn
- Testnet ETH (for deployment)

### Installation
```bash
git clone https://github.com/yaminidesai/defi-lending-protocol
cd defi-lending-protocol
npm install
```

### Compile Contracts
```bash
npx hardhat compile
```

### Run Tests
```bash
npx hardhat test
```

### Deploy Locally
```bash
# Terminal 1: Start local node
npx hardhat node

# Terminal 2: Deploy contracts
npx hardhat run scripts/deploy.js --network localhost
```

## Usage Examples

### As a Lender
```javascript
// Approve and deposit USDC
await usdc.approve(lendingPool.address, depositAmount);
await lendingPool.deposit(usdc.address, depositAmount);

// Withdraw anytime (if not used as collateral)
await lendingPool.withdraw(usdc.address, withdrawAmount);
```

### As a Borrower
```javascript
// Deposit ETH as collateral
await weth.approve(lendingPool.address, collateralAmount);
await lendingPool.deposit(weth.address, collateralAmount);

// Borrow USDC (up to 75% of collateral value)
await lendingPool.borrow(usdc.address, borrowAmount);

// Repay debt
await usdc.approve(lendingPool.address, repayAmount);
await lendingPool.repay(usdc.address, repayAmount);
```

### As a Liquidator
```javascript
// Monitor for unhealthy positions
const health = await lendingPool.getAccountHealth(borrower);

if (health < 8000) { // Below 80%
  await lendingPool.liquidate(
    borrower,
    borrowToken,
    collateralToken,
    repayAmount
  );
}
```

## Technical Decisions

### Why Over-Collateralization?

Unlike traditional finance, smart contracts cannot enforce legal recourse. The 75% collateral factor provides a buffer against volatility. Even with a 25% price drop, the protocol remains solvent.

### Why Custom Errors?

Custom errors save approximately 50 gas per revert compared to require strings. For a protocol handling millions in TVL, this adds up significantly.

### Why Immutable Oracle?

The oracle address is immutable to prevent admin rug-pulls. In production, this would be combined with governance-controlled oracle updates through a separate registry.

## Known Limitations

**Single Oracle Source** - Production systems should use multiple oracles with median pricing to prevent manipulation.

**No Flash Loan Protection** - While ReentrancyGuard helps, dedicated same-block borrow limits would be better.

**Fixed Parameters** - Collateral factors and liquidation thresholds are constants. These could be made governance-adjustable per asset.

**No Pause Mechanism** - Cannot emergency-stop in case of critical bug. This is intentional for true decentralization, but governance should have emergency powers.

## Gas Costs

Estimated costs on Ethereum mainnet (at 25 gwei):

| Operation | Gas | Cost (25 gwei) |
|-----------|-----|----------------|
| Deposit | ~80k | ~$0.50 |
| Withdraw | ~70k | ~$0.44 |
| Borrow | ~120k | ~$0.75 |
| Repay | ~100k | ~$0.63 |
| Liquidate | ~150k | ~$0.94 |

## Project Structure
```
contracts/
├── LendingPool.sol          # Core protocol logic
├── PriceOracle.sol          # Chainlink integration
└── interfaces/
    └── IPriceOracle.sol     # Oracle interface

test/
└── LendingPool.test.js      # Test suite

scripts/
└── deploy.js                # Deployment script

hardhat.config.js            # Hardhat configuration
```

## Security Considerations

### Implemented
✅ ReentrancyGuard on all state-changing functions  
✅ SafeERC20 for all token transfers  
✅ Custom errors for gas efficiency  
✅ Access control via Ownable  
✅ Integer overflow protection (Solidity 0.8+)  
✅ Price staleness checks  
✅ Liquidation amount limits  

### Production Requirements
⚠️ Professional security audit  
⚠️ Economic simulation and stress testing  
⚠️ Formal verification of critical paths  
⚠️ Bug bounty program  
⚠️ Gradual rollout with TVL caps  
⚠️ Multi-signature admin controls  
⚠️ Timelocked governance  

## What I Learned

Building this protocol taught me:
- How to handle precision in fixed-point math
- The importance of gas optimization in financial protocols
- Why oracle security is critical (price manipulation attacks)
- How interest rate curves affect market behavior
- The complexity of handling edge cases in liquidations

Most importantly: **DeFi hacks rarely come from Solidity bugs—they come from economic exploits.** Code security is table stakes; economic security is the hard part.

## Technologies Used

- **Solidity 0.8.20** - Smart contract language
- **Hardhat** - Development environment
- **OpenZeppelin** - Security-audited contract libraries
- **Chainlink** - Decentralized price oracles
- **ethers.js** - Ethereum interaction library

## Resources That Helped

- [Aave V2 Documentation](https://docs.aave.com/developers/) - Interest rate model
- [Compound Whitepaper](https://compound.finance/documents/Compound.Whitepaper.pdf) - Liquidation mechanics
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/) - Security patterns
- [Patrick Collins Tutorials](https://www.youtube.com/c/patrickcollins) - Solidity fundamentals

## Future Enhancements

- [ ] Flash loan functionality
- [ ] Variable collateral factors per asset
- [ ] Governance token and voting
- [ ] Protocol revenue distribution
- [ ] Cross-chain bridge integration
- [ ] Liquidity mining rewards

## License

MIT License - Feel free to use this code for learning or building your own projects.

## Contact

- **GitHub**: [@yaminidesai](https://github.com/yaminidesai)
- **Email**: ydesai2401@gmail.com

---
** If this project helped you understand DeFi development, consider starring the repo! ⭐
