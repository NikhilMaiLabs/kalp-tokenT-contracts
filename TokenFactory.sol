// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// Uniswap V2 interfaces for creating liquidity pools and routing
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router01} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router01.sol";

// OpenZeppelin utilities for secure contract patterns
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Local contract imports
import {BondingCurve} from "./BondingCurve.sol";
import {Token} from "./Token.sol";

/**
 * @title TokenFactory
 * @dev A factory contract that creates and manages tokens with bonding curve mechanics
 * @notice This contract implements a token launch mechanism where:
 *         1. Tokens start in FUNDING phase with bonding curve pricing
 *         2. Once funding goal is reached, liquidity is added to Uniswap/QuickSwap
 *         3. Tokens transition to TRADING phase on DEX
 */
contract TokenFactory is ReentrancyGuard, Ownable {
    
    /**
     * @dev Enum representing the lifecycle states of a token
     * NOT_CREATED: Token doesn't exist yet
     * FUNDING: Token is in bonding curve phase, collecting ETH
     * TRADING: Token has graduated to Uniswap trading
     */
    enum TokenState {
        NOT_CREATED,
        FUNDING,
        TRADING
    }

    // ============ CONSTANTS ============
    
    uint256 public constant MAX_SUPPLY = 10 ** 9 * 1 ether; // 1 billion tokens total supply
    uint256 public constant INITIAL_SUPPLY = (MAX_SUPPLY * 1) / 5; // 20% reserved for liquidity pool
    uint256 public constant FUNDING_SUPPLY = (MAX_SUPPLY * 4) / 5; // 80% available during funding phase
    uint256 public constant FUNDING_GOAL = 20 ether; // ETH needed to graduate to Uniswap
    uint256 public constant FEE_DENOMINATOR = 10000; // For basis point calculations (100% = 10000)

    // ============ STATE VARIABLES ============
    
    /// @dev Maps token addresses to their current state in the lifecycle
    mapping(address => TokenState) public tokens;
    
    /// @dev Tracks ETH collateral collected for each token during funding phase
    mapping(address => uint256) public collateral;
    
    /// @dev Implementation contract address for minimal proxy pattern
    address public immutable tokenImplementation;
    
    /// @dev Uniswap V2 router address for adding liquidity
    address public uniswapV2Router;
    
    /// @dev Uniswap V2 factory address for creating pairs
    address public uniswapV2Factory;
    
    /// @dev Bonding curve contract for pricing during funding phase
    BondingCurve public bondingCurve;
    
    /// @dev Fee percentage in basis points (e.g., 100 = 1%)
    uint256 public feePercent;
    
    /// @dev Accumulated fees available for withdrawal by owner
    uint256 public fee;

    // ============ EVENTS ============
    
    /// @dev Emitted when a new token is created and enters funding phase
    event TokenCreated(address indexed token, uint256 timestamp);
    
    /// @dev Emitted when a token graduates and liquidity is added to Uniswap
    event TokenLiqudityAdded(address indexed token, uint256 timestamp);

    /**
     * @dev Constructor sets up the factory with all required external contract addresses
     * @param _tokenImplementation Address of the token implementation for cloning
     * @param _uniswapV2Router Address of Uniswap V2 router for liquidity operations
     * @param _uniswapV2Factory Address of Uniswap V2 factory for pair creation
     * @param _bondingCurve Address of bonding curve contract for pricing
     * @param _feePercent Fee percentage in basis points
     */
    constructor(
        address _tokenImplementation,
        address _uniswapV2Router,
        address _uniswapV2Factory,
        address _bondingCurve,
        uint256 _feePercent
    ) Ownable(msg.sender) {
        tokenImplementation = _tokenImplementation;
        uniswapV2Router = _uniswapV2Router;
        uniswapV2Factory = _uniswapV2Factory;
        bondingCurve = BondingCurve(_bondingCurve);
        feePercent = _feePercent;
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @dev Updates the bonding curve contract address
     * @param _bondingCurve New bonding curve contract address
     * @notice Only owner can update this critical component
     */
    function setBondingCurve(address _bondingCurve) external onlyOwner {
        bondingCurve = BondingCurve(_bondingCurve);
    }

    /**
     * @dev Updates the fee percentage charged on transactions
     * @param _feePercent New fee percentage in basis points
     * @notice Only owner can modify fees
     */
    function setFeePercent(uint256 _feePercent) external onlyOwner {
        feePercent = _feePercent;
    }

    /**
     * @dev Allows owner to withdraw accumulated fees
     * @notice Transfers all accumulated fees to the owner and resets fee counter
     */
    function claimFee() external onlyOwner {
        (bool success, ) = msg.sender.call{value: fee}(new bytes(0));
        require(success, "ETH send failed");
        fee = 0;
    }

    // ============ TOKEN FUNCTIONS ============

    /**
     * @dev Creates a new token using minimal proxy pattern
     * @param name The name of the token (e.g., "MyToken")
     * @param symbol The ticker symbol of the token (e.g., "MTK")
     * @return The address of the newly created token contract
     * @notice Uses OpenZeppelin Clones for gas-efficient token deployment
     */
    function createToken(
        string memory name,
        string memory symbol
    ) external returns (address) {
        // Deploy a minimal proxy pointing to the token implementation
        address tokenAddress = Clones.clone(tokenImplementation);
        
        // Initialize the cloned token with name and symbol
        Token token = Token(tokenAddress);
        token.initialize(name, symbol);
        
        // Set token state to FUNDING phase
        tokens[tokenAddress] = TokenState.FUNDING;
        
        emit TokenCreated(tokenAddress, block.timestamp);
        return tokenAddress;
    }

    /**
     * @dev Allows users to buy tokens during the funding phase using ETH
     * @param tokenAddress The address of the token to buy
     * @notice Uses bonding curve pricing, charges fees, and handles graduation to Uniswap
     */
    function buy(address tokenAddress) external payable nonReentrant {
        require(tokens[tokenAddress] == TokenState.FUNDING, "Token not found");
        require(msg.value > 0, "ETH not enough");
        
        // ---- CALCULATE FEES AND CONTRIBUTIONS ----
        uint256 valueToBuy = msg.value;
        uint256 valueToReturn;
        uint256 tokenCollateral = collateral[tokenAddress];

        // Determine how much ETH is still needed to reach funding goal
        uint256 remainingEthNeeded = FUNDING_GOAL - tokenCollateral;
        
        // Calculate actual contribution after accounting for fees
        uint256 contributionWithoutFee = valueToBuy * FEE_DENOMINATOR / (FEE_DENOMINATOR + feePercent);
        
        // Cap contribution at what's needed to reach funding goal
        if (contributionWithoutFee > remainingEthNeeded) {
            contributionWithoutFee = remainingEthNeeded;
        }
        
        // Calculate fee and total amount to charge
        uint256 _fee = calculateFee(contributionWithoutFee, feePercent);
        uint256 totalCharged = contributionWithoutFee + _fee;
        
        // Calculate any excess ETH to return to buyer
        valueToReturn = valueToBuy > totalCharged ? valueToBuy - totalCharged : 0;
        fee += _fee;

        // ---- CALCULATE TOKEN AMOUNT USING BONDING CURVE ----
        Token token = Token(tokenAddress);
        uint256 amount = bondingCurve.getAmountOut(
            token.totalSupply(),
            contributionWithoutFee
        );
        
        // Ensure we don't exceed the funding supply allocation
        uint256 availableSupply = FUNDING_SUPPLY - token.totalSupply();
        require(amount <= availableSupply, "Token supply not enough");
        
        // ---- MINT TOKENS AND UPDATE STATE ----
        tokenCollateral += contributionWithoutFee;
        token.mint(msg.sender, amount);
        
        // ---- CHECK FOR GRADUATION TO UNISWAP ----
        // When funding goal is reached, graduate token to Uniswap trading
        if (tokenCollateral >= FUNDING_GOAL) {
            // Mint initial supply for liquidity provision
            token.mint(address(this), INITIAL_SUPPLY);
            
            // Create Uniswap pair and add liquidity
            address pair = createLiquilityPool(tokenAddress);
            uint256 liquidity = addLiquidity(
                tokenAddress,
                INITIAL_SUPPLY,
                tokenCollateral
            );
            
            // Burn LP tokens to permanently lock liquidity
            burnLiquidityToken(pair, liquidity);
            
            // Reset collateral and update token state
            tokenCollateral = 0;
            tokens[tokenAddress] = TokenState.TRADING;
            emit TokenLiqudityAdded(tokenAddress, block.timestamp);
        }
        
        collateral[tokenAddress] = tokenCollateral;
        
        // ---- RETURN EXCESS ETH ----
        if (valueToReturn > 0) {
            (bool success, ) = msg.sender.call{value: msg.value - valueToBuy}(
                new bytes(0)
            );
            require(success, "ETH send failed");
        }
    }

    /**
     * @dev Allows users to sell tokens back for ETH during funding phase
     * @param tokenAddress The address of the token to sell
     * @param amount The amount of tokens to sell
     * @notice Only available during FUNDING phase, uses bonding curve for pricing
     */
    function sell(address tokenAddress, uint256 amount) external nonReentrant {
        require(
            tokens[tokenAddress] == TokenState.FUNDING,
            "Token is not funding"
        );
        require(amount > 0, "Amount should be greater than zero");
        
        // ---- CALCULATE ETH TO RETURN USING BONDING CURVE ----
        Token token = Token(tokenAddress);
        uint256 receivedETH = bondingCurve.getFundsReceived(
            token.totalSupply(),
            amount
        );
        
        // ---- DEDUCT FEES ----
        uint256 _fee = calculateFee(receivedETH, feePercent);
        receivedETH -= _fee;
        fee += _fee;
        
        // ---- BURN TOKENS AND UPDATE COLLATERAL ----
        token.burn(msg.sender, amount);
        collateral[tokenAddress] -= receivedETH;
        
        // ---- SEND ETH TO SELLER ----
        //slither-disable-next-line arbitrary-send-eth
        (bool success, ) = msg.sender.call{value: receivedETH}(new bytes(0));
        require(success, "ETH send failed");
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @dev Creates a Uniswap V2 liquidity pool for the token
     * @param tokenAddress The token to create a pair for
     * @return The address of the created pair contract
     * @notice Creates a TOKEN/WETH pair on Uniswap V2
     */
    function createLiquilityPool(
        address tokenAddress
    ) internal returns (address) {
        IUniswapV2Factory factory = IUniswapV2Factory(uniswapV2Factory);
        IUniswapV2Router01 router = IUniswapV2Router01(uniswapV2Router);

        // Create the trading pair between token and WETH
        address pair = factory.createPair(tokenAddress, router.WETH());
        return pair;
    }

    /**
     * @dev Adds liquidity to the Uniswap pool using collected ETH and minted tokens
     * @param tokenAddress The token to add liquidity for
     * @param tokenAmount Amount of tokens to add to liquidity
     * @param ethAmount Amount of ETH to add to liquidity
     * @return The amount of LP tokens received
     * @notice This function provides initial liquidity using all collected ETH
     */
    function addLiquidity(
        address tokenAddress,
        uint256 tokenAmount,
        uint256 ethAmount
    ) internal returns (uint256) {
        Token token = Token(tokenAddress);
        IUniswapV2Router01 router = IUniswapV2Router01(uniswapV2Router);
        
        // Approve router to spend tokens for liquidity provision
        token.approve(uniswapV2Router, tokenAmount);
        
        // Add liquidity to Uniswap pool
        //slither-disable-next-line arbitrary-send-eth
        (, , uint256 liquidity) = router.addLiquidityETH{value: ethAmount}(
            tokenAddress,      // Token address
            tokenAmount,       // Amount of tokens to add
            tokenAmount,       // Minimum tokens (no slippage protection)
            ethAmount,         // Minimum ETH (no slippage protection)
            address(this),     // LP tokens sent to this contract
            block.timestamp    // Deadline for transaction
        );
        return liquidity;
    }

    /**
     * @dev Burns liquidity tokens to permanently lock liquidity
     * @param pair The Uniswap pair address
     * @param liquidity The amount of LP tokens to burn
     * @notice Sends LP tokens to address(0) to make liquidity removal impossible
     * @notice This ensures permanent liquidity for token holders
     */
    function burnLiquidityToken(address pair, uint256 liquidity) internal {
        // Transfer LP tokens to burn address (address(0)) to lock liquidity forever
        SafeERC20.safeTransfer(IERC20(pair), address(0), liquidity);
    }

    /**
     * @dev Calculates fee amount based on transaction value and fee percentage
     * @param _amount The base amount to calculate fee on
     * @param _feePercent Fee percentage in basis points (e.g., 100 = 1%)
     * @return The calculated fee amount
     * @notice Uses basis point math for precise fee calculations
     */
    function calculateFee(
        uint256 _amount,
        uint256 _feePercent
    ) internal pure returns (uint256) {
        // Calculate fee: (amount * feePercent) / 10000
        // Example: 1000 ETH * 100 bp / 10000 = 10 ETH (1% fee)
        return (_amount * _feePercent) / FEE_DENOMINATOR;
    }
}