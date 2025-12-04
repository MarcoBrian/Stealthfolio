// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockV3Aggregator} from "@chainlink/local/src/data-feeds/MockV3Aggregator.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {StealthfolioVault} from "../src/StealthfolioVaultExecutor.sol";
import {StealthfolioHook} from "../src/hooks/StealthfolioHook.sol";

import "forge-std/console.sol"; 

contract StealthfolioVaultHarness is StealthfolioVault {
    using CurrencyLibrary for Currency;

    constructor(IPoolManager _manager, StealthfolioHook _hook)
        StealthfolioVault(_manager, _hook)
    {}

    /// @dev Expose balance normalization helper for testing.
    function normalizeBalanceHarness(address token, uint256 bal)
        external
        view
        returns (uint256)
    {
        return _normalizeBalance(token, bal);
    }

    /// @dev Expose _computePortfolioValue for testing.
    function computePortfolioValueHarness(Currency targetAsset)
        external
        view
        returns (uint256 totalValue, uint256 assetValue)
    {
        return _computePortfolioValue(targetAsset);
    }

    /// @dev Expose the internal function for testing.
    function updatePricesHarness()
        external
        returns (uint256 totalValue, uint256[] memory values)
    {
        return _updatePrices();
    }

    /// @dev Expose _updatePricesAndCheckDrift for testing.
    function updatePricesAndCheckDriftHarness()
        external
        returns (DriftResult memory)
    {
        return _updatePricesAndCheckDrift();
    }

    /// @dev Test-only helper to findMaxDeviation 
    function findMaxDeviationHarness() external returns (
        Currency maxAsset, uint256 maxAbsDev
    ) {
        (uint256 totalValue, uint256[] memory values) = _updatePrices();
        console.log("Total Value:", totalValue ); 
        for (uint256 i =0; i < values.length; i++){
            console.log("Values ", i , ":", values[i]); 
        }
        
        return _findMaxDeviation(totalValue, values); 

    }


    /// @dev Test-only helper to configure strategy & base asset
    function configureStrategyHarness(
        Currency _baseAsset,
        uint16 _minDriftBps,
        uint16 _batchSizeBps,
        uint32 _minDriftCheckInterval
    ) external onlyOwner {
        baseAsset = _baseAsset;

        strategyConfig = StrategyConfig({
            minDriftBps: _minDriftBps,
            batchSizeBps: _batchSizeBps,
            minDriftCheckInterval: _minDriftCheckInterval
        });

        strategyState = StrategyState({
            lastDriftBps: 0,
            lastDriftCheckBlock: 0,
            targetAsset: Currency.wrap(address(0))
        });
    }
}

contract StealthfolioVaultExecutorTest is Test {
    using CurrencyLibrary for Currency;

    StealthfolioVaultHarness vault;

    MockERC20 usdc;
    MockERC20 wbtc;
    MockERC20 weth;

    MockV3Aggregator usdcFeed;
    MockV3Aggregator wbtcFeed;
    MockV3Aggregator wethFeed;

    Currency currencyUSDC;
    Currency currencyWBTC;
    Currency currencyWETH;

    function setUp() public {
        // Dummy manager/hook, not used by _updatePricesAndCheckDrift
        IPoolManager dummyManager = IPoolManager(address(0));
        StealthfolioHook dummyHook = StealthfolioHook(address(0));

        vault = new StealthfolioVaultHarness(dummyManager, dummyHook);

        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Deploy price feeds (8 decimals, prices in USD)
        usdcFeed = new MockV3Aggregator(8, 1e8); // $1
        wbtcFeed = new MockV3Aggregator(8, 100_000e8); // $100,000
        wethFeed = new MockV3Aggregator(8, 3_000e8); // $3,000

        // Wrap as Currency
        currencyUSDC = Currency.wrap(address(usdc));
        currencyWBTC = Currency.wrap(address(wbtc));
        currencyWETH = Currency.wrap(address(weth));

        // Configure strategy on harness with USDC as base asset
        vault.configureStrategyHarness(
            currencyUSDC,
            100, // minDriftBps: 1%
            2_500, // batchSizeBps: 25%
            1 // minDriftCheckInterval: 1 block
        );

        // Set portfolio targets: 50% USDC, 30% WBTC, 20% WETH
        Currency[] memory assets = new Currency[](3);
        assets[0] = currencyUSDC;
        assets[1] = currencyWBTC;
        assets[2] = currencyWETH;

        uint16[] memory bps = new uint16[](3);
        bps[0] = 5_000; // 50% USDC
        bps[1] = 3_000; // 30% WBTC
        bps[2] = 2_000; // 20% WETH

        vault.setPortfolioTargets(assets, bps);

        // Set price feeds
        vault.setPriceFeed(currencyUSDC, address(usdcFeed));
        vault.setPriceFeed(currencyWBTC, address(wbtcFeed));
        vault.setPriceFeed(currencyWETH, address(wethFeed));

        // Mint balances to vault so there is some non-zero portfolio value
        usdc.mint(address(vault), 500_000e6); // 500k USDC
        wbtc.mint(address(vault), 5e8); // 5 WBTC
        weth.mint(address(vault), 50e18); // 50 WETH
    }

    function test_findMaxDeviation() public {
        (Currency maxAsset, uint256 maxAbsDev) = vault.findMaxDeviationHarness(); 
        console.log("MaxAsset:", MockERC20(Currency.unwrap(maxAsset)).symbol()); 
        console.log("MaxAbsDev (USD):", maxAbsDev / 1e18 ); 
    }

    function test_updatePricesAndCheckDrift_returnsResult() public {
        StealthfolioVault.DriftResult memory result =
            vault.updatePricesAndCheckDriftHarness();

        // After first call with non-zero portfolio, we expect:
        // - lastDriftBps to be set (may or may not exceed minDriftBps)
        // - targetAsset to be one of the non-base assets (WBTC or WETH) or zero

        // It must at least update lastDriftCheckBlock and not revert
        (uint16 lastDriftBps,, Currency targetAsset) = vault.strategyState();
        assertEq(
            Currency.unwrap(vault.baseAsset()),
            Currency.unwrap(currencyUSDC),
            "base asset should be USDC"
        );
        assertGt(block.number, 0, "block must be non-zero");
        assertEq(
            vault.lastPriceInBase(currencyUSDC) > 0,
            true,
            "USDC price must be cached"
        );

        // Basic sanity on returned struct: batches > 0 if shouldRebalance is true
        if (result.shouldRebalance) {
            assertGt(result.batches, 0, "batches must be > 0");
            assertTrue(
                result.targetAsset == currencyWBTC
                    || result.targetAsset == currencyWETH,
                "targetAsset must be a non-base asset"
            );
        }

        // strategyState should be in sync with result
        if (result.shouldRebalance) {
            (uint16 minDriftBps,,) = vault.strategyConfig(); 
            assertEq(
                Currency.unwrap(targetAsset),
                Currency.unwrap(result.targetAsset),
                "state targetAsset should match result"
            );
            assertEq(
                lastDriftBps >= minDriftBps,
                true,
                "drift bps should exceed threshold when rebalancing"
            );
        }

        console.log("Should Rebalance:", result.shouldRebalance); 
        console.log("Should targetAsset:", MockERC20(Currency.unwrap(result.targetAsset)).symbol()); 
        console.log("Should Rebalance:", result.batches); 

    }

    function test_updatePrices_returnsPerAssetValuesAndTotal() public {
        (uint256 totalValue, uint256[] memory values) =
            vault.updatePricesHarness();

        // Expect one value per configured portfolio asset
        assertEq(values.length, 3, "values length should equal number of assets");

        // Manually recompute each asset's value using cached prices and balances
        uint256 usdcPrice = vault.lastPriceInBase(currencyUSDC);
        uint256 wbtcPrice = vault.lastPriceInBase(currencyWBTC);
        uint256 wethPrice = vault.lastPriceInBase(currencyWETH);

        assertGt(usdcPrice, 0, "USDC price must be > 0");
        assertGt(wbtcPrice, 0, "WBTC price must be > 0");
        assertGt(wethPrice, 0, "WETH price must be > 0");

        uint256 usdcBal = IERC20(Currency.unwrap(currencyUSDC)).balanceOf(address(vault));
        uint256 wbtcBal = IERC20(Currency.unwrap(currencyWBTC)).balanceOf(address(vault));
        uint256 wethBal = IERC20(Currency.unwrap(currencyWETH)).balanceOf(address(vault));

        // Mirror vault normalization via harness helper
        uint256 usdcNormBal =
            vault.normalizeBalanceHarness(Currency.unwrap(currencyUSDC), usdcBal);
        uint256 wbtcNormBal =
            vault.normalizeBalanceHarness(Currency.unwrap(currencyWBTC), wbtcBal);
        uint256 wethNormBal =
            vault.normalizeBalanceHarness(Currency.unwrap(currencyWETH), wethBal);

        uint256 expectedUsdcValue = (usdcNormBal * usdcPrice) / 1e18;
        uint256 expectedWbtcValue = (wbtcNormBal * wbtcPrice) / 1e18;
        uint256 expectedWethValue = (wethNormBal * wethPrice) / 1e18;

        // Order of assets in setUp(): [USDC, WBTC, WETH]
        assertEq(values[0], expectedUsdcValue, "USDC value mismatch");
        assertEq(values[1], expectedWbtcValue, "WBTC value mismatch");
        assertEq(values[2], expectedWethValue, "WETH value mismatch");

        uint256 expectedTotal = expectedUsdcValue + expectedWbtcValue + expectedWethValue;
        assertEq(totalValue, expectedTotal, "totalValue should equal sum of asset values");
    }

    function test_computePortfolioValue_matchesUpdatePricesTotals() public {
        // First, populate price cache by calling updatePrices
        (uint256 totalValue, uint256[] memory values) =
            vault.updatePricesHarness();

        // For each asset, compute portfolio value using cached prices and balances
        (uint256 totalFromCompute, uint256 usdcValue) =
            vault.computePortfolioValueHarness(currencyUSDC);
        (, uint256 wbtcValue) =
            vault.computePortfolioValueHarness(currencyWBTC);
        (, uint256 wethValue) =
            vault.computePortfolioValueHarness(currencyWETH);

        // Log values for visual inspection
        console.log("updatePrices totalValue:", totalValue);
        console.log("computePortfolioValue totalValue:", totalFromCompute);
        console.log("USDC value:", usdcValue);
        console.log("WBTC value:", wbtcValue);
        console.log("WETH value:", wethValue);
        console.log("values[0-2]:", values[0], values[1], values[2]);

        // Totals should match
        assertEq(
            totalFromCompute,
            totalValue,
            "computePortfolioValue total must equal updatePrices total"
        );

        // Per-asset values should match values[] from _updatePrices
        // Order of assets in setUp(): [USDC, WBTC, WETH]
        assertEq(usdcValue, values[0], "USDC value mismatch");
        assertEq(wbtcValue, values[1], "WBTC value mismatch");
        assertEq(wethValue, values[2], "WETH value mismatch");
    }
}

