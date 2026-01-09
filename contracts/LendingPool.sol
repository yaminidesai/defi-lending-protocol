// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IPriceOracle.sol";

/**
 * @title LendingPool
 * @notice Main lending pool contract for collateralized borrowing and lending
 * @dev Implements dynamic interest rates and automated liquidations
 */
contract LendingPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Price oracle for token valuations
    IPriceOracle public immutable priceOracle;
    
    // Protocol parameters (in basis points, 10000 = 100%)
    uint256 public constant COLLATERAL_FACTOR = 7500; // 75%
    uint256 public constant LIQUIDATION_THRESHOLD = 8000; // 80%
    uint256 public constant LIQUIDATION_BONUS = 500; // 5%
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    
    // Interest rate model parameters (annual rates in basis points)
    uint256 public baseRate = 200; // 2%
    uint256 public multiplier = 1000; // 10%
    uint256 public kink = 8000; // 80% utilization
    uint256 public jumpMultiplier = 5000; // 50%
    
    // Market data for each token
    struct Market {
        bool isListed;
        uint256 totalDeposits;
        uint256 totalBorrows;
        uint256 lastAccrualTime;
        uint256 borrowIndex; // Accumulated interest index
    }
    
    // User account data per token
    struct UserAccount {
        uint256 deposited;
        uint256 borrowed;
        uint256 borrowIndex; // Index when user last borrowed
    }
    
    // token => Market
    mapping(address => Market) public markets;
    
    // user => token => UserAccount
    mapping(address => mapping(address => UserAccount)) public accounts;
    
    // List of all supported tokens
    address[] public supportedTokens;
    
    // Events
    event MarketListed(address indexed token);
    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    event Borrow(address indexed user, address indexed token, uint256 amount);
    event Repay(address indexed user, address indexed token, uint256 amount);
    event Liquidate(
        address indexed liquidator,
        address indexed borrower,
        address indexed collateralToken,
        address borrowToken,
        uint256 repayAmount,
        uint256 collateralSeized
    );
    event InterestAccrued(address indexed token, uint256 newBorrowIndex);
    
    // Custom errors
    error MarketNotListed();
    error MarketAlreadyListed();
    error InvalidAmount();
    error InsufficientBalance();
    error InsufficientCollateral();
    error AccountNotLiquidatable();
    error RepayAmountTooHigh();
    error NoPriceAvailable();
    
    constructor(address _priceOracle) Ownable(msg.sender) {
        if (_priceOracle == address(0)) revert InvalidAmount();
        priceOracle = IPriceOracle(_priceOracle);
    }
    
    /**
     * @notice List a new token market
     * @param token ERC20 token address
     */
    function listMarket(address token) external onlyOwner {
        if (markets[token].isListed) revert MarketAlreadyListed();
        
        markets[token] = Market({
            isListed: true,
            totalDeposits: 0,
            totalBorrows: 0,
            lastAccrualTime: block.timestamp,
            borrowIndex: 1e18
        });
        
        supportedTokens.push(token);
        emit MarketListed(token);
    }
    
    /**
     * @notice Deposit tokens as collateral
     * @param token Token to deposit
     * @param amount Amount to deposit
     */
    function deposit(address token, uint256 amount) external nonReentrant {
        if (!markets[token].isListed) revert MarketNotListed();
        if (amount == 0) revert InvalidAmount();
        
        accrueInterest(token);
        
        Market storage market = markets[token];
        UserAccount storage account = accounts[msg.sender][token];
        
        market.totalDeposits += amount;
        account.deposited += amount;
        
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        emit Deposit(msg.sender, token, amount);
    }
    
    /**
     * @notice Withdraw deposited collateral
     * @param token Token to withdraw
     * @param amount Amount to withdraw
     */
    function withdraw(address token, uint256 amount) external nonReentrant {
        if (!markets[token].isListed) revert MarketNotListed();
        if (amount == 0) revert InvalidAmount();
        
        UserAccount storage account = accounts[msg.sender][token];
        if (account.deposited < amount) revert InsufficientBalance();
        
        accrueInterest(token);
        
        // Check if withdrawal would make account unhealthy
        uint256 tokenPrice = priceOracle.getPrice(token);
        uint256 withdrawValue = (amount * tokenPrice) / 1e18;
        
        if (getAccountLiquidity(msg.sender) < withdrawValue) {
            revert InsufficientCollateral();
        }
        
        Market storage market = markets[token];
        market.totalDeposits -= amount;
        account.deposited -= amount;
        
        IERC20(token).safeTransfer(msg.sender, amount);
        
        emit Withdraw(msg.sender, token, amount);
    }
    
    /**
     * @notice Borrow tokens against collateral
     * @param token Token to borrow
     * @param amount Amount to borrow
     */
    function borrow(address token, uint256 amount) external nonReentrant {
        if (!markets[token].isListed) revert MarketNotListed();
        if (amount == 0) revert InvalidAmount();
        
        accrueInterest(token);
        
        uint256 tokenPrice = priceOracle.getPrice(token);
        uint256 borrowValue = (amount * tokenPrice) / 1e18;
        
        if (getAccountLiquidity(msg.sender) < borrowValue) {
            revert InsufficientCollateral();
        }
        
        Market storage market = markets[token];
        UserAccount storage account = accounts[msg.sender][token];
        
        // Update user's borrow index if first borrow
        if (account.borrowed == 0) {
            account.borrowIndex = market.borrowIndex;
        } else {
            // Accrue interest for existing borrows
            uint256 interest = _calculateBorrowInterest(account, market);
            account.borrowed += interest;
            account.borrowIndex = market.borrowIndex;
        }
        
        market.totalBorrows += amount;
        account.borrowed += amount;
        
        IERC20(token).safeTransfer(msg.sender, amount);
        
        emit Borrow(msg.sender, token, amount);
    }
    
    /**
     * @notice Repay borrowed tokens
     * @param token Token to repay
     * @param amount Amount to repay
     */
    function repay(address token, uint256 amount) external nonReentrant {
        if (!markets[token].isListed) revert MarketNotListed();
        if (amount == 0) revert InvalidAmount();
        
        accrueInterest(token);
        
        Market storage market = markets[token];
        UserAccount storage account = accounts[msg.sender][token];
        
        uint256 borrowedWithInterest = _getBorrowBalance(account, market);
        uint256 repayAmount = amount > borrowedWithInterest ? borrowedWithInterest : amount;
        
        market.totalBorrows -= repayAmount;
        account.borrowed = borrowedWithInterest - repayAmount;
        account.borrowIndex = market.borrowIndex;
        
        IERC20(token).safeTransferFrom(msg.sender, address(this), repayAmount);
        
        emit Repay(msg.sender, token, repayAmount);
    }
    
    /**
     * @notice Liquidate an undercollateralized position
     * @param borrower Address of borrower to liquidate
     * @param borrowToken Token that was borrowed
     * @param collateralToken Token used as collateral
     * @param repayAmount Amount of debt to repay
     */
    function liquidate(
        address borrower,
        address borrowToken,
        address collateralToken,
        uint256 repayAmount
    ) external nonReentrant {
        if (!markets[borrowToken].isListed || !markets[collateralToken].isListed) {
            revert MarketNotListed();
        }
        
        accrueInterest(borrowToken);
        accrueInterest(collateralToken);
        
        // Check if borrower is liquidatable
        uint256 healthFactor = getAccountHealth(borrower);
        if (healthFactor >= LIQUIDATION_THRESHOLD) {
            revert AccountNotLiquidatable();
        }
        
        UserAccount storage borrowAccount = accounts[borrower][borrowToken];
        uint256 totalDebt = _getBorrowBalance(borrowAccount, markets[borrowToken]);
        
        // Can only liquidate up to 50% of debt
        if (repayAmount > totalDebt / 2) revert RepayAmountTooHigh();
        
        // Calculate collateral to seize (with bonus)
        uint256 borrowPrice = priceOracle.getPrice(borrowToken);
        uint256 collateralPrice = priceOracle.getPrice(collateralToken);
        
        uint256 repayValue = (repayAmount * borrowPrice) / 1e18;
        uint256 collateralValue = (repayValue * (BASIS_POINTS + LIQUIDATION_BONUS)) / BASIS_POINTS;
        uint256 collateralAmount = (collateralValue * 1e18) / collateralPrice;
        
        UserAccount storage collateralAccount = accounts[borrower][collateralToken];
        if (collateralAccount.deposited < collateralAmount) {
            revert InsufficientBalance();
        }
        
        // Update state
        markets[borrowToken].totalBorrows -= repayAmount;
        borrowAccount.borrowed = totalDebt - repayAmount;
        borrowAccount.borrowIndex = markets[borrowToken].borrowIndex;
        
        markets[collateralToken].totalDeposits -= collateralAmount;
        collateralAccount.deposited -= collateralAmount;
        
        // Transfer tokens
        IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), repayAmount);
        IERC20(collateralToken).safeTransfer(msg.sender, collateralAmount);
        
        emit Liquidate(
            msg.sender,
            borrower,
            collateralToken,
            borrowToken,
            repayAmount,
            collateralAmount
        );
    }
    
    /**
     * @notice Accrue interest for a market
     * @param token Market token
     */
    function accrueInterest(address token) public {
        Market storage market = markets[token];
        
        uint256 timeElapsed = block.timestamp - market.lastAccrualTime;
        if (timeElapsed == 0) return;
        
        uint256 borrowRate = getBorrowRate(token);
        uint256 interestFactor = (borrowRate * timeElapsed) / SECONDS_PER_YEAR;
        
        market.borrowIndex = (market.borrowIndex * (1e18 + interestFactor)) / 1e18;
        market.lastAccrualTime = block.timestamp;
        
        emit InterestAccrued(token, market.borrowIndex);
    }
    
    /**
     * @notice Calculate current borrow interest rate
     * @param token Market token
     * @return Annual borrow rate in basis points
     */
    function getBorrowRate(address token) public view returns (uint256) {
        Market memory market = markets[token];
        
        if (market.totalDeposits == 0) return baseRate;
        
        uint256 utilization = (market.totalBorrows * BASIS_POINTS) / market.totalDeposits;
        
        if (utilization <= kink) {
            return baseRate + (utilization * multiplier) / BASIS_POINTS;
        } else {
            uint256 normalRate = baseRate + (kink * multiplier) / BASIS_POINTS;
            uint256 excessUtil = utilization - kink;
            return normalRate + (excessUtil * jumpMultiplier) / BASIS_POINTS;
        }
    }
    
    /**
     * @notice Get available borrowing capacity for user
     * @param user User address
     * @return Available liquidity in USD (18 decimals)
     */
    function getAccountLiquidity(address user) public view returns (uint256) {
        uint256 totalCollateralValue = 0;
        uint256 totalBorrowValue = 0;
        
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            UserAccount memory account = accounts[user][token];
            uint256 price = priceOracle.getPrice(token);
            
            // Add collateral value
            totalCollateralValue += (account.deposited * price * COLLATERAL_FACTOR) / (1e18 * BASIS_POINTS);
            
            // Add borrow value
            if (account.borrowed > 0) {
                uint256 borrowBalance = _getBorrowBalance(account, markets[token]);
                totalBorrowValue += (borrowBalance * price) / 1e18;
            }
        }
        
        return totalCollateralValue > totalBorrowValue 
            ? totalCollateralValue - totalBorrowValue 
            : 0;
    }
    
    /**
     * @notice Get account health factor
     * @param user User address
     * @return Health factor in basis points (8000 = liquidation threshold)
     */
    function getAccountHealth(address user) public view returns (uint256) {
        uint256 totalCollateralValue = 0;
        uint256 totalBorrowValue = 0;
        
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            UserAccount memory account = accounts[user][token];
            uint256 price = priceOracle.getPrice(token);
            
            totalCollateralValue += (account.deposited * price) / 1e18;
            
            if (account.borrowed > 0) {
                uint256 borrowBalance = _getBorrowBalance(account, markets[token]);
                totalBorrowValue += (borrowBalance * price) / 1e18;
            }
        }
        
        if (totalBorrowValue == 0) return type(uint256).max;
        
        return (totalCollateralValue * BASIS_POINTS) / totalBorrowValue;
    }
    
    /**
     * @notice Get user's current borrow balance with interest
     * @param account User account data
     * @param market Market data
     * @return Total borrow balance including accrued interest
     */
    function _getBorrowBalance(
        UserAccount memory account,
        Market memory market
    ) internal pure returns (uint256) {
        if (account.borrowed == 0) return 0;
        return (account.borrowed * market.borrowIndex) / account.borrowIndex;
    }
    
    /**
     * @notice Calculate accrued interest on borrow
     */
    function _calculateBorrowInterest(
        UserAccount memory account,
        Market memory market
    ) internal pure returns (uint256) {
        return _getBorrowBalance(account, market) - account.borrowed;
    }
    
    /**
     * @notice Get number of supported tokens
     */
    function getSupportedTokensCount() external view returns (uint256) {
        return supportedTokens.length;
    }
}
