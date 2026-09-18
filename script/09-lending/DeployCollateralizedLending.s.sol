// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {CollateralizedLending} from "../../src/09-lending/CollateralizedLending.sol";
import {MockPriceOracle} from "../../src/09-lending/MockPriceOracle.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploys CollateralizedLending, a MockPriceOracle, a demo borrow asset (like USDC) and
///         a demo collateral asset (like WETH), fully wired and priced, ready to borrow against.
/// @dev Run with:
///   forge script script/09-lending/DeployCollateralizedLending.s.sol --rpc-url <RPC_URL> --broadcast
contract DeployCollateralizedLending is Script {
    uint256 public constant RATE_PER_SECOND = 317; // ~1% APR, 1e18-scaled
    uint256 public constant MAX_PRICE_AGE = 1 hours;
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 8_000; // 80%
    uint256 public constant LIQUIDATION_BONUS_BPS = 500; // 5%
    uint256 public constant CLOSE_FACTOR_BPS = 5_000; // 50%
    uint256 public constant COLLATERAL_FACTOR_BPS = 7_500; // 75%

    uint256 public constant DEMO_WETH_PRICE = 2_000e18; // $2000
    uint256 public constant DEMO_USDC_PRICE = 1e18; // $1

    function run()
        external
        returns (CollateralizedLending lending, MockPriceOracle oracle, MockERC20 usdc, MockERC20 weth)
    {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        usdc = new MockERC20("Demo USD Coin", "DUSDC", 18);
        weth = new MockERC20("Demo Wrapped ETH", "DWETH", 18);
        oracle = new MockPriceOracle(deployer);

        lending = new CollateralizedLending(
            IERC20(address(usdc)),
            oracle,
            RATE_PER_SECOND,
            MAX_PRICE_AGE,
            LIQUIDATION_THRESHOLD_BPS,
            LIQUIDATION_BONUS_BPS,
            CLOSE_FACTOR_BPS,
            deployer
        );

        lending.addCollateralAsset(address(weth), COLLATERAL_FACTOR_BPS);
        oracle.setPrice(address(weth), DEMO_WETH_PRICE);
        oracle.setPrice(address(usdc), DEMO_USDC_PRICE);

        usdc.mint(deployer, 1_000_000e18);
        weth.mint(deployer, 1_000e18);

        vm.stopBroadcast();

        console2.log("CollateralizedLending deployed at:", address(lending));
        console2.log("MockPriceOracle deployed at:", address(oracle));
        console2.log("Demo borrow token (USDC-like) at:", address(usdc));
        console2.log("Demo collateral token (WETH-like) at:", address(weth));
        console2.log("Call lending.supplyLiquidity(amount) with USDC before anyone can borrow.");
    }
}
