// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockPriceOracle
/// @notice Owner-fed price feed. Prices are USD value scaled to 1e18 per 1e18 units of the asset
///         (i.e. per whole token, assuming 18-decimal tokens). Tracks the timestamp of the last
///         update per asset so consumers can reject stale or missing data.
contract MockPriceOracle is Ownable {
    struct PriceData {
        uint256 price;
        uint256 updatedAt;
        bool exists;
    }

    mapping(address => PriceData) private _prices;

    event PriceSet(address indexed asset, uint256 price, uint256 updatedAt);

    error AssetNotSupported();

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setPrice(address asset, uint256 price) external onlyOwner {
        _prices[asset] = PriceData({price: price, updatedAt: block.timestamp, exists: true});
        emit PriceSet(asset, price, block.timestamp);
    }

    /// @notice Reverts if the asset has never had a price set (distinguishes "missing" from "zero").
    function getPrice(address asset) external view returns (uint256 price, uint256 updatedAt) {
        PriceData storage p = _prices[asset];
        if (!p.exists) revert AssetNotSupported();
        return (p.price, p.updatedAt);
    }
}
