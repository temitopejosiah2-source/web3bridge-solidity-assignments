// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title GovToken
/// @notice Simple ERC20Votes governance token. Voting power only counts once a holder self-delegates
///         (or is delegated to), per the standard OpenZeppelin checkpoint pattern.
contract GovToken is ERC20Votes {
    constructor(string memory name_, string memory symbol_, uint256 initialSupply, address initialHolder)
        ERC20(name_, symbol_)
        EIP712(name_, "1")
    {
        _mint(initialHolder, initialSupply);
    }

    /// @dev Use block.timestamp instead of block.number for checkpoints, so tests can move the
    ///      voting clock with vm.warp as required by the assignment's Foundry rules.
    function clock() public view override returns (uint48) {
        return SafeCast.toUint48(block.timestamp);
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }
}
