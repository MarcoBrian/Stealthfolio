// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";


import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockV3Aggregator} from "@chainlink/local/src/data-feeds/MockV3Aggregator.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey, PoolIdLibrary} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {StealthfolioVault} from "../src/StealthfolioVaultExecutor.sol";
import {StealthfolioHook} from "../src/hooks/StealthfolioHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CalculatePrice} from "../src/utils/CalculatePrice.sol";

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

    /// @dev Expose _computeBatchParams for testing
    function computeBatchParamsHarness()
        external
        view
        returns (BatchParams memory)
    {
        return _computeBatchParams();
    }

    /// @dev Helper to set targetAsset in strategy state for testing
    function setTargetAssetHarness(Currency asset) external {
        strategyState.targetAsset = asset;
    }

    /// @dev Expose _computeSwapDirection() for testing
    function computeSwapDirectionHarness(
            Currency asset, 
            PoolKey memory poolKey, 
            int256 dev
    ) external pure returns (bool) {
        return _computeSwapDirection(asset, poolKey, dev); 
    } 


}

contract StealthfolioVaultExecutorTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    StealthfolioVaultHarness vault;
    StealthfolioHook hook;


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

        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();


        // Deploy hook
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("StealthfolioHook.sol", abi.encode(manager), hookAddress);
        hook = StealthfolioHook(hookAddress);

        vault = new StealthfolioVaultHarness(manager, hook);

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


    // ======================
    // Configuration Tests for the Vault 
    // ======================    

    function testConfigureStrategy_SetsFieldsCorrectly() public {
        uint16 minDriftBpsInput = 100; 
        uint16 batchSizeBpsInput = 5000; 
        uint32 minDriftCheckIntervalInput = 2; 

        vault.configureStrategy(minDriftBpsInput, batchSizeBpsInput, minDriftCheckIntervalInput); 
        (uint16 minDriftBpsOutput, uint16 batchSizeBpsOutput, uint32 minDriftCheckIntervalOutput) = vault.strategyConfig(); 
        assertEq(minDriftBpsOutput, minDriftBpsInput, "minDriftBps mismatch");
        assertEq(batchSizeBpsOutput, batchSizeBpsInput, "batchSizeBps mismatch");
        assertEq(minDriftCheckIntervalOutput, minDriftCheckIntervalInput, "minDriftCheckInterval mismatch");

        (uint16 lastDriftBpsOutput, uint32 lastDriftCheckBlockOutput, Currency targetAssetOutput) = vault.strategyState(); 
        assertEq(lastDriftBpsOutput, 0);
        assertEq(lastDriftCheckBlockOutput, 0); 
        assertEq(Currency.unwrap(targetAssetOutput),address(0)); 

    }

    function testSetPortfolioTargets_ValidInputStoresState() public {
        
        // Configure strategy to set baseAsset (required before setPortfolioTargets)
        vault.configureStrategyHarness(
            currencyUSDC, // baseAsset
            100, // minDriftBps
            2_500, // batchSizeBps
            1 // minDriftCheckInterval
        );

        // Set portfolio targets: 50% USDC, 25% WBTC, 25% WETH
        Currency[] memory assets = new Currency[](3);
        assets[0] = currencyUSDC;
        assets[1] = currencyWBTC;
        assets[2] = currencyWETH;

        uint16[] memory bps = new uint16[](3);
        bps[0] = 5_000; // 50% USDC
        bps[1] = 2_500; // 25% WBTC
        bps[2] = 2_500; // 25% WETH

        vault.setPortfolioTargets(assets, bps);

        // Assert: portfolioAssets.length == 3
        assertEq(Currency.unwrap(vault.portfolioAssets(0)), Currency.unwrap(currencyUSDC), "portfolioAssets[0] should be USDC");
        assertEq(Currency.unwrap(vault.portfolioAssets(1)), Currency.unwrap(currencyWBTC), "portfolioAssets[1] should be WBTC");
        assertEq(Currency.unwrap(vault.portfolioAssets(2)), Currency.unwrap(currencyWETH), "portfolioAssets[2] should be WETH");

        // Assert: targetAllocBps values are correct
        assertEq(vault.targetAllocBps(currencyUSDC), 5_000, "USDC allocation should be 5000 bps");
        assertEq(vault.targetAllocBps(currencyWBTC), 2_500, "WBTC allocation should be 2500 bps");
        assertEq(vault.targetAllocBps(currencyWETH), 2_500, "WETH allocation should be 2500 bps");

        // Assert: baseAsset is in the portfolio (this is validated in setPortfolioTargets, but we verify it's set)
        assertEq(Currency.unwrap(vault.baseAsset()), Currency.unwrap(currencyUSDC), "baseAsset should be USDC");
        
        // Verify baseAsset is actually in portfolioAssets array
        bool baseFound = false;
        for (uint256 i = 0; i < 3; i++) {
            if (vault.portfolioAssets(i) == vault.baseAsset()) {
                baseFound = true;
                break;
            }
        }
        assertTrue(baseFound, "baseAsset must be in portfolioAssets");
    }


    // ======================
    // Configuration Tests for the Vault  - Negative tests
    // ======================


    function testSetPortfolioTargets_RevertsIfTotalBpsNot10000() public {
        // Configure strategy to set baseAsset (required before setPortfolioTargets)
        vault.configureStrategyHarness(
            currencyUSDC, // baseAsset
            100, // minDriftBps
            2_500, // batchSizeBps
            1 // minDriftCheckInterval
        );

        // Set portfolio targets with invalid total: 50% USDC, 30% WBTC, 25% WETH = 10,500 bps (should be 10,000)
        Currency[] memory assets = new Currency[](3);
        assets[0] = currencyUSDC;
        assets[1] = currencyWBTC;
        assets[2] = currencyWETH;

        uint16[] memory bps = new uint16[](3);
        bps[0] = 5_000; // 50% USDC
        bps[1] = 3_000; // 30% WBTC
        bps[2] = 2_500; // 25% WETH (total = 10,500, not 10,000)

        vm.expectRevert("TOTAL_BPS_NEQ_100");
        vault.setPortfolioTargets(assets, bps);
    }

    function testSetPortfolioTargets_RevertsIfBaseNotInPortfolio() public {
        // Configure strategy with USDC as baseAsset
        vault.configureStrategyHarness(
            currencyUSDC, // baseAsset
            100,
            2_500,
            1
        );

        // Set portfolio targets without baseAsset (only WBTC and WETH)
        Currency[] memory assets = new Currency[](2);
        assets[0] = currencyWBTC;
        assets[1] = currencyWETH;

        uint16[] memory bps = new uint16[](2);
        bps[0] = 5_000; // 50% WBTC
        bps[1] = 5_000; // 50% WETH

        vm.expectRevert("BASE_NOT_IN_PORTFOLIO");
        vault.setPortfolioTargets(assets, bps);
    }

    function testSetPortfolioTargets_RevertsIfBpsZero() public {
        // Configure strategy to set baseAsset
        vault.configureStrategyHarness(
            currencyUSDC,
            100,
            2_500,
            1
        );

        // Set portfolio targets with zero BPS for one asset
        Currency[] memory assets = new Currency[](3);
        assets[0] = currencyUSDC;
        assets[1] = currencyWBTC;
        assets[2] = currencyWETH;

        uint16[] memory bps = new uint16[](3);
        bps[0] = 5_000; // 50% USDC
        bps[1] = 0; // 0% WBTC (should revert)
        bps[2] = 5_000; // 50% WETH

        vm.expectRevert("BPS_ZERO");
        vault.setPortfolioTargets(assets, bps);
    }

    function testSetPortfolioTargets_RevertsIfAssetZero() public {
        // Configure strategy to set baseAsset
        vault.configureStrategyHarness(
            currencyUSDC,
            100,
            2_500,
            1
        );

        // Set portfolio targets with zero address for one asset
        Currency[] memory assets = new Currency[](3);
        assets[0] = currencyUSDC;
        assets[1] = Currency.wrap(address(0)); // Zero address (should revert)
        assets[2] = currencyWETH;

        uint16[] memory bps = new uint16[](3);
        bps[0] = 5_000; // 50% USDC
        bps[1] = 2_500; // 25% (invalid asset)
        bps[2] = 2_500; // 25% WETH

        vm.expectRevert("ASSET_ZERO");
        vault.setPortfolioTargets(assets, bps);
    }

    function testSetPortfolioTargets_RevertsIfArraysLengthMismatch() public {
        // Configure strategy to set baseAsset
        vault.configureStrategyHarness(
            currencyUSDC,
            100,
            2_500,
            1
        );

        // Set portfolio targets with mismatched array lengths
        Currency[] memory assets = new Currency[](3);
        assets[0] = currencyUSDC;
        assets[1] = currencyWBTC;
        assets[2] = currencyWETH;

        uint16[] memory bps = new uint16[](2); // Only 2 BPS values for 3 assets
        bps[0] = 5_000;
        bps[1] = 5_000;

        vm.expectRevert("ASSETS_BPS_LEN");
        vault.setPortfolioTargets(assets, bps);
    }


    // ======= Test functions functionality =========

    function test_findMaxDeviation() public {
        (Currency maxAsset, uint256 maxAbsDev) = vault.findMaxDeviationHarness(); 
        console.log("MaxAsset:", MockERC20(Currency.unwrap(maxAsset)).symbol()); 
        console.log("MaxAbsDev (USD):", maxAbsDev / 1e18 ); 
    }


    // ======================
    // Batch Computation Tests - computeBatchParams() 
    // ======================
    
    
    function testComputeSwapDirection_AssetIsToken0_DevPositive_BuysAsset() public {
         Currency asset = currencyWBTC;
        PoolKey memory key = PoolKey({
            currency0: asset,          // WBTC
            currency1: currencyUSDC,   // USDC
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });


        // dev > 0 => asset underweight => we BUY asset with base
        int256 dev = int256(1);

        bool zeroForOne = vault.computeSwapDirectionHarness(asset, key, dev);

        // When asset is token0 and dev > 0, we expect:
        // zeroForOne = false (pay token1 (USDC), receive token0 (WBTC))
        assertFalse(zeroForOne, "asset underweight & token0 => should buy asset (zeroForOne=false)");

       
    }
    
    function testComputeSwapDirection_AssetIsToken0_DevNegative_SellsAsset() public {
        Currency asset = currencyWBTC;
        PoolKey memory key = PoolKey({
            currency0: asset,
            currency1: currencyUSDC,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // dev < 0 => asset overweight => we SELL asset for base
        int256 dev = -1;

        bool zeroForOne = vault.computeSwapDirectionHarness(asset, key, dev);

        // asset is token0, dev < 0 => zeroForOne = true (pay token0, receive token1)
        assertTrue(zeroForOne, "asset overweight & token0 => should sell asset (zeroForOne=true)");
    }
    
    function testComputeSwapDirection_AssetIsToken1_DevPositive_BuysAsset() public {
      Currency asset = currencyWBTC;
        PoolKey memory key = PoolKey({
            currency0: currencyUSDC, //USDC
            currency1: asset,   // WBTC
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });


        // dev > 0 => asset underweight => we BUY asset with base
        int256 dev = int256(1);

        bool zeroForOne = vault.computeSwapDirectionHarness(asset, key, dev);

        // When asset is token1 and dev > 0, we expect:
        // zeroForOne = true (pay token1 (USDC), receive token0 (WBTC))
        assertTrue(zeroForOne, "asset underweight & token1 => should buy asset (zeroForOne=true)");

       
    }
    
    function testComputeSwapDirection_AssetIsToken1_DevNegative_SellsAsset() public {
        Currency asset = currencyWBTC;
        PoolKey memory key = PoolKey({
            currency0: currencyUSDC, //USDC
            currency1: asset,   // WBTC
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });


        // dev < 0 => asset overweight => we SELL asset
        int256 dev = int256(-1);

        bool zeroForOne = vault.computeSwapDirectionHarness(asset, key, dev);
        assertFalse(zeroForOne, "asset overweight & token1 => should sell asset (zeroForOne=False)");

    }

    // ====== AmountSpecified Scaling Tests ============
    function testComputeBatchParams_OverweightWBTC_AmountSpecifiedUsesWBTCBalance() public {

    }

    function  testComputeBatchParams_AssetUnderweight_AmountSpecifiedUsesBaseBalance() public {

    }

    function testComputeBatchParams_ZeroDeviation_ReturnsZeroAmount() public {

    }



    // ======================
    // Drift Detection Test - updatePricesAndCheckDrift()
    // ======================
    function testUpdatePricesAndCheckDrift_RevertsIfNoBaseAssetConfigured() public {
        // Create a fresh vault without configuring baseAsset
        StealthfolioVaultHarness freshVault = new StealthfolioVaultHarness(manager, hook);
        
        // Don't configure strategy (baseAsset will be address(0))
        // Attempt to call updatePricesAndCheckDrift without baseAsset configured
        vm.expectRevert("NO_BASE");
        freshVault.updatePricesAndCheckDriftHarness();
    }

    function testUpdatePricesAndCheckDrift_ReturnsNoRebalanceOnZeroTotal() public {
        // Create a fresh vault
        StealthfolioVaultHarness freshVault = new StealthfolioVaultHarness(manager, hook);
        
        // Configure strategy with baseAsset
        freshVault.configureStrategyHarness(
            currencyUSDC,
            100, // minDriftBps
            2_500, // batchSizeBps
            1 // minDriftCheckInterval
        );

        // Set portfolio targets
        Currency[] memory assets = new Currency[](3);
        assets[0] = currencyUSDC;
        assets[1] = currencyWBTC;
        assets[2] = currencyWETH;

        uint16[] memory bps = new uint16[](3);
        bps[0] = 5_000; // 50% USDC
        bps[1] = 3_000; // 30% WBTC
        bps[2] = 2_000; // 20% WETH

        freshVault.setPortfolioTargets(assets, bps);

        // Set price feeds
        freshVault.setPriceFeed(currencyUSDC, address(usdcFeed));
        freshVault.setPriceFeed(currencyWBTC, address(wbtcFeed));
        freshVault.setPriceFeed(currencyWETH, address(wethFeed));

        // Don't mint any balances - vault will have zero total value
        // Call updatePricesAndCheckDrift - should return early with shouldRebalance = false
        StealthfolioVault.DriftResult memory result = freshVault.updatePricesAndCheckDriftHarness();

        // Assert: shouldRebalance should be false when totalValue is 0
        assertFalse(result.shouldRebalance, "shouldRebalance should be false when totalValue is 0");
        assertEq(Currency.unwrap(result.targetAsset), address(0), "targetAsset should be zero address when totalValue is 0");
        assertEq(result.batches, 0, "batches should be 0 when totalValue is 0");
    }

    function testUpdatePricesAndCheckDrift_BelowDriftThreshold_NoRebalance() public {
        // Create a fresh vault
        StealthfolioVaultHarness freshVault = new StealthfolioVaultHarness(manager, hook);
        
        // Configure strategy with a high minDriftBps threshold (5% = 500 bps)
        // This ensures small drifts won't trigger rebalancing
        freshVault.configureStrategyHarness(
            currencyUSDC,
            500, // minDriftBps: 5% (high threshold)
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

        freshVault.setPortfolioTargets(assets, bps);

        // Set price feeds
        freshVault.setPriceFeed(currencyUSDC, address(usdcFeed));
        freshVault.setPriceFeed(currencyWBTC, address(wbtcFeed));
        freshVault.setPriceFeed(currencyWETH, address(wethFeed));

        // Mint balances that are very close to target allocations
        // This will result in a small drift (< 5%) that should NOT trigger rebalancing
        // Target portfolio value: ~$1,000,000
        // - USDC: $500k (50%) = 500,000 USDC (exactly on target)
        // - WBTC: $300k (30%) = 3 WBTC (exactly on target)  
        // - WETH: $200k (20%) = 66.67 WETH (exactly on target)
        
        // Mint exactly at target to ensure drift is minimal (near 0%)
        usdc.mint(address(freshVault), 500_000e6); // $500k USDC
        wbtc.mint(address(freshVault), 3e8); // 3 WBTC = $300k
        weth.mint(address(freshVault), 66_666_666_666_666_666_666); // ~66.67 WETH = $200k

        // Call updatePricesAndCheckDrift - drift should be below 5% threshold
        StealthfolioVault.DriftResult memory result = freshVault.updatePricesAndCheckDriftHarness();

        // Assert: shouldRebalance should be false when drift is below minDriftBps threshold
        assertFalse(result.shouldRebalance, "shouldRebalance should be false when drift is below threshold");
        
        // Verify that lastDriftBps was set (even if below threshold)
        (uint16 lastDriftBps,,) = freshVault.strategyState();
        assertLt(lastDriftBps, 500, "lastDriftBps should be less than minDriftBps (500)");
        
        // The targetAsset may be set even if shouldRebalance is false
        // This is expected behavior per the implementation (line 339)
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

