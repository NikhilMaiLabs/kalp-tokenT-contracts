// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {FixedPointMathLib} from "./FixedPointMathLib.sol";

/**
 * @title BondingCurve
 * @dev Exponential bonding curve implementation for dynamic token pricing
 * 
 * This contract implements an exponential bonding curve with the formula:
 * Price(x) = A * e^(B * x)
 * 
 * Where:
 * - x = current token supply
 * - A = base price multiplier (scaling factor)
 * - B = growth rate parameter (steepness of curve)
 * - e = Euler's number (~2.718)
 * 
 * Key properties:
 * - Price increases exponentially as more tokens are minted
 * - Early buyers get lower prices, later buyers pay premium
 * - Creates natural price discovery and liquidity incentives
 * - Mathematically ensures continuous liquidity
 */
contract BondingCurve {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    /// @notice Base price multiplier parameter in the exponential curve
    /// @dev Immutable scaling factor that affects the overall price level
    uint256 public immutable A;
    
    /// @notice Growth rate parameter that controls curve steepness
    /// @dev Immutable exponent coefficient - higher values = steeper price increases
    uint256 public immutable B;

    /**
     * @notice Constructor to set bonding curve parameters
     * @dev These parameters are immutable once set and define the curve shape
     * @param _a Base price multiplier (A parameter)
     * @param _b Growth rate coefficient (B parameter)
     */
    constructor(uint256 _a, uint256 _b) {
        A = _a;
        B = _b;
    }

    /**
     * @notice Calculate ETH received when selling a specific amount of tokens
     * @dev Implements integration of exponential curve: ∫[x1 to x0] A*e^(B*x) dx
     * 
     * Mathematical derivation:
     * - Integral of A*e^(B*x) = (A/B) * e^(B*x)
     * - Area under curve from x1 to x0 = (A/B) * (e^(B*x0) - e^(B*x1))
     * - Where x1 = x0 - deltaX (new supply after selling)
     * 
     * @param x0 Current token supply before selling
     * @param deltaX Number of tokens being sold
     * @return deltaY Amount of ETH that will be received
     * 
     * Example: If selling 1000 tokens from supply of 10000:
     * - x0 = 10000, deltaX = 1000
     * - x1 = 9000 (new supply after sale)
     * - Returns ETH equivalent to area under curve between these points
     */
    function getFundsReceived(
        uint256 x0,
        uint256 deltaX
    ) public view returns (uint256 deltaY) {
        uint256 a = A;
        uint256 b = B;
        
        // Ensure we don't sell more tokens than available
        require(x0 >= deltaX, "Cannot sell more tokens than current supply");
        
        // Calculate exponential values at both endpoints
        // exp(b*x0) = e^(B * current_supply)
        int256 exp_b_x0 = (int256(b.mulWad(x0))).expWad();
        // exp(b*x1) = e^(B * new_supply) where x1 = x0 - deltaX
        int256 exp_b_x1 = (int256(b.mulWad(x0 - deltaX))).expWad();

        // Calculate the difference between exponentials
        // This represents the definite integral value
        uint256 delta = uint256(exp_b_x0 - exp_b_x1);
        
        // Apply the (A/B) coefficient to get final ETH amount
        // deltaY = (A/B) * (exp(B*x0) - exp(B*x1))
        deltaY = a.fullMulDiv(delta, b);
    }

    /**
     * @notice Calculate number of tokens that can be purchased with given ETH
     * @dev Solves inverse problem: given deltaY (ETH), find deltaX (tokens)
     * 
     * Mathematical approach:
     * 1. Start with: deltaY = (A/B) * (e^(B*x0) - e^(B*x1))
     * 2. Rearrange: e^(B*x1) = e^(B*x0) - (deltaY*B/A)
     * 3. Solve for x1: x1 = ln(e^(B*x0) - (deltaY*B/A)) / B
     * 4. Calculate deltaX = x1 - x0
     * 
     * @param x0 Current token supply before purchase
     * @param deltaY Amount of ETH being spent
     * @return deltaX Number of tokens that can be purchased
     * 
     * Example: If spending 1 ETH when supply is 5000:
     * - Calculates new supply x1 after purchase
     * - Returns deltaX = x1 - x0 (tokens received)
     */
    function getAmountOut(
        uint256 x0,
        uint256 deltaY
    ) public view returns (uint256 deltaX) {
        uint256 a = A;
        uint256 b = B;
        
        // Calculate current exponential value: e^(B*x0)
        uint256 exp_b_x0 = uint256((int256(b.mulWad(x0))).expWad());

        // Calculate new exponential value after purchase
        // exp(B*x1) = exp(B*x0) + (deltaY*B/A)
        // Note: Addition because we're moving right on curve (increasing supply)
        uint256 exp_b_x1 = exp_b_x0 + deltaY.fullMulDiv(b, a);

        // Solve for new token supply: x1 = ln(exp_b_x1) / B
        // Then calculate token difference: deltaX = x1 - x0
        deltaX = uint256(int256(exp_b_x1).lnWad()).divWad(b) - x0;
    }
}