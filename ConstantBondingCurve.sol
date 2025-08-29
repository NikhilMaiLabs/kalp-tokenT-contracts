// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title ConstantBondingCurve
 * @dev A simple constant bonding curve contract for token pricing
 * 
 * This contract implements a linear bonding curve where the price remains constant.
 * The exchange rate is fixed at FUNDING_SUPPLY tokens per FUNDING_GOAL ETH.
 * 
 * Key characteristics:
 * - Linear relationship between ETH and tokens
 * - No slippage or price impact
 * - Fixed exchange rate of 40M tokens per ETH (800M / 20)
 */
contract ConstantBondingCurve {
    /// @notice Total token supply available for funding phase
    /// @dev 800 million tokens with 18 decimal places
    uint256 public constant FUNDING_SUPPLY = 800_000_000 ether;
    
    /// @notice Target ETH amount to raise during funding
    /// @dev 20 ETH funding goal
    uint256 public constant FUNDING_GOAL = 20 ether;

    /**
     * @notice Calculate how many tokens can be bought with given ETH amount
     * @dev Uses simple proportion: tokens = (ethAmount * totalTokens) / totalEth
     * @param ethAmount Amount of ETH being spent
     * @return uint256 Number of tokens that can be purchased
     * 
     * Formula: tokenAmount = (ethAmount * FUNDING_SUPPLY) / FUNDING_GOAL
     * Example: 1 ETH = (1 * 800M) / 20 = 40M tokens
     */
    function calculateBuyReturn(
        uint256 ethAmount
    ) public pure returns (uint256) {
        return (ethAmount * FUNDING_SUPPLY) / FUNDING_GOAL;
    }

    /**
     * @notice Calculate how much ETH can be received for selling tokens
     * @dev Inverse of buy calculation: eth = (tokenAmount * totalEth) / totalTokens
     * @param tokenAmount Number of tokens being sold
     * @return uint256 Amount of ETH that will be received
     * 
     * Formula: ethAmount = (tokenAmount * FUNDING_GOAL) / FUNDING_SUPPLY
     * Example: 40M tokens = (40M * 20) / 800M = 1 ETH
     */
    function calculateSellReturn(
        uint256 tokenAmount
    ) public pure returns (uint256) {
        return (tokenAmount * FUNDING_GOAL) / FUNDING_SUPPLY;
    }
}