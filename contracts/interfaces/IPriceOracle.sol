// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPriceOracle
 * @notice Interface for price oracle contracts
 */
interface IPriceOracle {
    /**
     * @notice Get the price of a token in USD
     * @param token Address of the token
     * @return price Price with 18 decimals
     */
    function getPrice(address token) external view returns (uint256 price);
}
