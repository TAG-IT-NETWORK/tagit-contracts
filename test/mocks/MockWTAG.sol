// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockWTAG
 * @notice Minimal mock of WrappedTAGIT (wTAG) for testing TGE conversion
 * @dev Simulates the ERC20Burnable wTAG token from tagit-bridge.
 *      The real WrappedTAGIT restricts mint/burn to the bridge adapter;
 *      this mock allows owner to mint for test setup and standard burn() for conversion.
 */
contract MockWTAG is ERC20, ERC20Burnable, Ownable {
    constructor(address initialOwner) ERC20("Wrapped TAGIT", "wTAG") Ownable(initialOwner) {}

    /**
     * @notice Mint wTAG tokens (test helper)
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
