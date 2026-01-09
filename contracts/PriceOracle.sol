// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "./interfaces/IPriceOracle.sol";

/**
 * @title PriceOracle
 * @notice Price oracle using Chainlink price feeds with fallback mechanism
 * @dev Provides token prices in USD with 18 decimal precision
 */
contract PriceOracle is IPriceOracle, Ownable {
    // Constants (stored in bytecode, not storage - saves gas)
    uint256 private constant PRICE_PRECISION = 1e18;
    uint256 private constant STALENESS_THRESHOLD = 1 hours;
    
    // Chainlink price feeds for each token
    mapping(address => AggregatorV3Interface) public priceFeeds;
    
    // Fallback prices for testing (token => price in USD with 18 decimals)
    mapping(address => uint256) public fallbackPrices;
    
    // Events
    event PriceFeedUpdated(address indexed token, address indexed priceFeed);
    event FallbackPriceSet(address indexed token, uint256 price);
    
    // Custom errors (cheaper than require strings)
    error InvalidTokenAddress();
    error InvalidPriceFeedAddress();
    error PriceMustBePositive();
    error InvalidPriceFromFeed();
    error StalePrice();
    error NoPriceAvailable();
    
    constructor() Ownable(msg.sender) {}
    
    /**
     * @notice Set Chainlink price feed for a token
     * @param token Token address
     * @param priceFeed Chainlink aggregator address
     */
    function setPriceFeed(address token, address priceFeed) external onlyOwner {
        if (token == address(0)) revert InvalidTokenAddress();
        if (priceFeed == address(0)) revert InvalidPriceFeedAddress();
        
        priceFeeds[token] = AggregatorV3Interface(priceFeed);
        emit PriceFeedUpdated(token, priceFeed);
    }
    
    /**
     * @notice Set fallback price for testing or emergency use
     * @param token Token address
     * @param price Price in USD with 18 decimals
     */
    function setFallbackPrice(address token, uint256 price) external onlyOwner {
        if (price == 0) revert PriceMustBePositive();
        fallbackPrices[token] = price;
        emit FallbackPriceSet(token, price);
    }
    
    /**
     * @notice Get current price of a token in USD
     * @param token Token address
     * @return Price with 18 decimals
     */
    function getPrice(address token) external view override returns (uint256) {
        AggregatorV3Interface priceFeed = priceFeeds[token];
        
        // Try to get price from Chainlink
        if (address(priceFeed) != address(0)) {
            try priceFeed.latestRoundData() returns (
                uint80,
                int256 answer,
                uint256,
                uint256 updatedAt,
                uint80
            ) {
                if (answer <= 0) revert InvalidPriceFromFeed();
                if (updatedAt <= block.timestamp - STALENESS_THRESHOLD) revert StalePrice();
                
                // Cache decimals call and convert to 18 decimals
                uint8 decimals = priceFeed.decimals();
                unchecked {
                    // Safe because we know decimals <= 18 for Chainlink feeds
                    return uint256(answer) * (10 ** (18 - decimals));
                }
            } catch {
                // If Chainlink fails, fall through to fallback
            }
        }
        
        // Use fallback price
        uint256 fallbackPrice = fallbackPrices[token];
        if (fallbackPrice == 0) revert NoPriceAvailable();
        return fallbackPrice;
    }
}
