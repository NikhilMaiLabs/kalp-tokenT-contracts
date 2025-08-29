// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// Import OpenZeppelin upgradeable contracts for ERC20 token functionality and ownership management
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title Token
 * @dev A simple upgradeable ERC20 token contract with mint and burn functionality
 * @notice This contract inherits from OpenZeppelin's upgradeable contracts to support proxy patterns
 */
contract Token is ERC20Upgradeable, OwnableUpgradeable {
    
    /**
     * @dev Initializes the token contract with name and symbol
     * @param name The name of the token (e.g., "MyToken")
     * @param symbol The symbol of the token (e.g., "MTK")
     * @notice This function replaces the constructor in upgradeable contracts
     * @notice Can only be called once due to the initializer modifier
     */
    function initialize(
        string memory name,
        string memory symbol
    ) public initializer {
        // Initialize the ERC20 functionality with the provided name and symbol
        __ERC20_init(name, symbol);
        
        // Set the deployer as the initial owner of the contract
        __Ownable_init(msg.sender);
    }

    /**
     * @dev Mints new tokens to a specified address
     * @param to The address that will receive the newly minted tokens
     * @param amount The amount of tokens to mint (in wei units)
     * @notice Only the contract owner can call this function
     * @notice This increases the total supply of tokens
     */
    function mint(address to, uint256 amount) public onlyOwner {
        // Use OpenZeppelin's internal _mint function to create new tokens
        _mint(to, amount);
    }

    /**
     * @dev Burns tokens from a specified address
     * @param to The address from which tokens will be burned
     * @param amount The amount of tokens to burn (in wei units)
     * @notice Only the contract owner can call this function
     * @notice This decreases the total supply of tokens
     * @notice The address must have sufficient balance for the burn to succeed
     */
    function burn(address to, uint256 amount) public onlyOwner {
        // Use OpenZeppelin's internal _burn function to destroy tokens
        _burn(to, amount);
    }
}