// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";


import {PoolManager} from "v4-core/PoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {StealthfolioHook} from "../src/hooks/StealthfolioHook.sol";
import {StealthfolioVault} from "../src/StealthfolioVaultExecutor.sol";
import {MockV3Aggregator} from "@chainlink/local/src/data-feeds/MockV3Aggregator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CalculatePrice} from '../src/utils/CalculatePrice.sol';

import "forge-std/console.sol";

// Minimal harness to expose internal functions for testing
contract StealthfolioVaultHarness is StealthfolioVault {
    constructor(IPoolManager _manager, StealthfolioHook _hook)
        StealthfolioVault(_manager, _hook)
    {}

    function normalizeBalanceHarness(address token, uint256 bal)
        external
        view
        returns (uint256)
    {
        return _normalizeBalance(token, bal);
    }

    function updatePricesHarness()
        external
        returns (uint256 totalValue, uint256[] memory values)
    {
        return _updatePrices();
    }
}

contract StealthfolioTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    StealthfolioHook hook;
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
    
    PoolKey wbtcPoolKey;
    PoolKey wethPoolKey;
    PoolId wbtcPoolId;
    PoolId wethPoolId;

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;


    function setUp() public {
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        uint8 usdcDecimals = 6 ; 
        uint8 wbtcDecimals = 8 ; 
        uint8 wethDecimals = 18; 


        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", usdcDecimals);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", wbtcDecimals);
        weth = new MockERC20("Wrapped Ether", "WETH", wethDecimals);
        
        // Deploy price feeds (8 decimals, prices in USD)
        usdcFeed = new MockV3Aggregator(8, 1e8); // $1
        wbtcFeed = new MockV3Aggregator(8, 100000e8); // $100,000
        wethFeed = new MockV3Aggregator(8, 3000e8); // $3,000
        
        // Convert to Currency
        currencyUSDC = Currency.wrap(address(usdc));
        currencyWBTC = Currency.wrap(address(wbtc));
        currencyWETH = Currency.wrap(address(weth));

        // Deploy hook
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("StealthfolioHook.sol", abi.encode(manager), hookAddress);
        hook = StealthfolioHook(hookAddress);
        
        // Deploy vault
        vault = new StealthfolioVaultHarness(manager, hook);
        
        // Configure hook
        hook.configureHook(
            address(vault),
            currencyUSDC,
            10, // rebalanceCooldown: 10 blocks
            100, // rebalanceMaxDuration: 100 blocks
            1e18 // maxExternalSwapAmount: 1e18
        );
        
        // Mint tokens to vault
        usdc.mint(address(vault), 1000000e6); // 1M USDC
        wbtc.mint(address(vault), 10e8); // 10 WBTC
        weth.mint(address(vault), 100e18); // 100 WETH


        // Calculate BTCUSD SqrtPrice

        (Currency token0, Currency token1, uint160 sqrtPriceBTC_USDC) = 
                            CalculatePrice.computeInitSqrtPrice(currencyWBTC, 
                            currencyUSDC, 
                            wbtcDecimals, 
                            usdcDecimals, 100_000); 


        console.log("Token 0: ", MockERC20(Currency.unwrap(token0)).symbol()); 

        
        // Create pools swaps
        // Create BTC/USDC Pool 
        wbtcPoolKey = PoolKey({
            currency0: token0,
            currency1: token1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        wbtcPoolId = wbtcPoolKey.toId();

        uint160 sqrtPriceWETH_USDC; 
        ( token0,  token1, sqrtPriceWETH_USDC) = 
        CalculatePrice.computeInitSqrtPrice(currencyWETH, 
                                            currencyUSDC, 
                                            wethDecimals, 
                                            usdcDecimals, 
                                            3_000); 

        console.log("Token 0: ", MockERC20(Currency.unwrap(token0)).symbol()); 

        
        // Create WETH/USDC Pool 
        wethPoolKey = PoolKey({
            currency0: token0,
            currency1: token1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        wethPoolId = wethPoolKey.toId();
        
        // Register pools on hook
        hook.registerStrategyPool(wbtcPoolKey);
        hook.registerStrategyPool(wethPoolKey);
        
        // Set rebalance pools
        hook.setRebalancePool(currencyWBTC, wbtcPoolKey);
        hook.setRebalancePool(currencyWETH, wethPoolKey);
        
        // Initialize pools and add liquidity
        manager.initialize(wbtcPoolKey, sqrtPriceBTC_USDC);
        manager.initialize(wethPoolKey, sqrtPriceWETH_USDC);
        
        // Add liquidity to pools (mint tokens to this contract first)
        usdc.mint(address(this), 10_000_000e6);
        wbtc.mint(address(this), 100e8);
        weth.mint(address(this), 1000e18);
        
        usdc.approve(address(manager), type(uint256).max);
        wbtc.approve(address(manager), type(uint256).max);
        weth.approve(address(manager), type(uint256).max);


        usdc.approve(address(modifyLiquidityRouter), type(uint256).max);
        wbtc.approve(address(modifyLiquidityRouter), type(uint256).max);
        weth.approve(address(modifyLiquidityRouter), type(uint256).max);


        usdc.approve(address(swapRouter), type(uint256).max);
        wbtc.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);

        // Tick Math calculation for BTC / USDC Pair 

        int24 currentTickBTCUSDC = TickMath.getTickAtSqrtPrice(sqrtPriceBTC_USDC);

        // Tick Math calculation for WETH / USDC Pair 
        int24 currentTickWETHUSDC = TickMath.getTickAtSqrtPrice(sqrtPriceWETH_USDC); 

        console.log("BTC Sqrt Price:", sqrtPriceBTC_USDC); 
        console.log("BTC current Tick: " , currentTickBTCUSDC);
        console.log("");
        console.log("WETH Sqrt Price:", sqrtPriceWETH_USDC); 
        console.log("WETH Current Tick:", currentTickWETHUSDC); 

        int24 tickLowerBTCUSDC = (currentTickBTCUSDC / TICK_SPACING - 1) * TICK_SPACING;
        int24 tickUpperBTCUSDC = (currentTickBTCUSDC / TICK_SPACING + 1) * TICK_SPACING;
        

        int24 tickLowerWETHUSDC = (currentTickWETHUSDC / TICK_SPACING - 10) * TICK_SPACING;
        int24 tickUpperWETHUSDC = (currentTickWETHUSDC / TICK_SPACING + 10) * TICK_SPACING;

        uint160 sqrtPriceLowerX96BTCUSD = TickMath.getSqrtPriceAtTick(tickLowerBTCUSDC);
        uint160 sqrtPriceUpperX96BTCUSD = TickMath.getSqrtPriceAtTick(tickUpperBTCUSDC);

        uint160 sqrtPriceLowerX96WETHUSD = TickMath.getSqrtPriceAtTick(tickLowerWETHUSDC);
        uint160 sqrtPriceUpperX96WETHUSD = TickMath.getSqrtPriceAtTick(tickUpperWETHUSDC);


        uint256 amount0USDCDesired = 1_000_000e6; // 1M USDC
        uint256 amount1WBTCDesired = 10e8;        // 10 WBTC    


        uint256 amountUSDCDesired = 300_000e6; // 300,000 in USDC
        uint256 amount1WETHDesired = 100e18;        // 100 WETH    


        uint128 liquidityBTCUSD = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceBTC_USDC, 
            sqrtPriceLowerX96BTCUSD,
            sqrtPriceUpperX96BTCUSD,
            amount0USDCDesired,
            amount1WBTCDesired
        );

        uint128 liquidityWETHUSD = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceWETH_USDC, 
            sqrtPriceLowerX96WETHUSD,
            sqrtPriceUpperX96WETHUSD,
            amountUSDCDesired,
            amount1WETHDesired
        );


        // Add liquidity using modifyLiquidityRouter - WBTC
        ModifyLiquidityParams memory liqParamsBTC = ModifyLiquidityParams({
            tickLower: tickLowerBTCUSDC,
            tickUpper: tickUpperBTCUSDC,
            liquidityDelta: int256(uint256(liquidityBTCUSD)),
            salt: bytes32(0)
        });

        // Add liquidity using modifyLiquidityRouter - WETH
        ModifyLiquidityParams memory liqParamsWETH = ModifyLiquidityParams({
            tickLower: tickLowerWETHUSDC,
            tickUpper: tickUpperWETHUSDC,
            liquidityDelta: int256(uint256(liquidityWETHUSD)),
            salt: bytes32(0)
        });


        (uint256 amount0, uint256 amount1) =
        LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceBTC_USDC,
            sqrtPriceLowerX96BTCUSD,
            sqrtPriceUpperX96BTCUSD,
            liquidityBTCUSD
        );

        console.log("Amount 0 BTCUSD:", amount0); 
        console.log("Amount 1 BTCUSD:", amount1); 

        (amount0, amount1) =
        LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceWETH_USDC,
            sqrtPriceLowerX96WETHUSD,
            sqrtPriceUpperX96WETHUSD,
            liquidityWETHUSD
        );


        console.log("Amount 0 WETHUSD:", amount0); 
        console.log("Amount 1 WETHUSD:", amount1); 
        
        modifyLiquidityRouter.modifyLiquidity(wbtcPoolKey, liqParamsBTC, bytes(""));
        modifyLiquidityRouter.modifyLiquidity(wethPoolKey, liqParamsWETH, bytes(""));
        
        // Configure vault
        vault.configureStrategy(
            100, // minDriftBps: 1%
            2500, // batchSizeBps: 25% per batch
            1 // minDriftCheckInterval: 1 block
        );
        
        // Set portfolio targets: 50% USDC, 30% WBTC, 20% WETH
        Currency[] memory assets = new Currency[](3);
        assets[0] = currencyUSDC;
        assets[1] = currencyWBTC;
        assets[2] = currencyWETH;
        
        uint16[] memory bps = new uint16[](3);
        bps[0] = 5000; // 50% USDC
        bps[1] = 3000; // 30% WBTC
        bps[2] = 2000; // 20% WETH
        
        vault.setPortfolioTargets(assets, bps);
        
        // Set price feeds
        vault.setPriceFeed(currencyUSDC, address(usdcFeed));
        vault.setPriceFeed(currencyWBTC, address(wbtcFeed));
        vault.setPriceFeed(currencyWETH, address(wethFeed));


    }

    // ======= Test Hook <-> Vault Interaction ===================

    function testRebalanceStep_StartsRebalanceAndExecutesFirstBatch() public {
        // Arrange: ensure there is significant drift by changing WBTC price
        // Original price in setUp is 100,000; cut it in half to create underweight WBTC
        wbtcFeed.updateAnswer(50_000e8);

        // Rebalance state should be idle before calling vault.rebalanceStep
        (
            bool pendingBefore,
            uint32 nextBatchBlockBefore,
            uint32 batchesRemainingBefore,
            uint256 lastRebalanceBlockBefore,
            Currency targetAssetBefore
        ) = hook.rebalanceState();

        assertFalse(pendingBefore, "rebalance should not be pending before");
        assertEq(batchesRemainingBefore, 0, "no batches should be scheduled before");
        assertEq(Currency.unwrap(targetAssetBefore), address(0), "no target asset before");
        assertEq(nextBatchBlockBefore, 0, "nextBatchBlock should be zero before");
        assertEq(lastRebalanceBlockBefore, 0, "lastRebalanceBlock should be zero before");

        // Capture vault balances before rebalance step
        uint256 usdcBefore = usdc.balanceOf(address(vault));
        uint256 wbtcBefore = wbtc.balanceOf(address(vault));
        uint256 wethBefore = weth.balanceOf(address(vault));

        console.log("Vault balances before rebalance:");
        console.log("USDC:", usdcBefore);
        console.log("WBTC:", wbtcBefore);
        console.log("WETH:", wethBefore);

        // Act: call rebalanceStep from the vault owner (this test contract)
        vault.rebalanceStep();

        // Assert: hook rebalance state reflects that a rebalance window started
        (
            bool pending,
            uint32 nextBatchBlock,
            uint32 batchesRemaining,
            uint256 lastRebalanceBlock,
            Currency hookTargetAsset
        ) = hook.rebalanceState();

        console.log("Hook rebalance state after first rebalanceStep:");
        console.log("pending:", pending);
        console.log("nextBatchBlock:", nextBatchBlock);
        console.log("batchesRemaining:", batchesRemaining);
        console.log("lastRebalanceBlock:", lastRebalanceBlock);
        console.log(
            "hook targetAsset:",
            Currency.unwrap(hookTargetAsset)
        );

        // Either we have an ongoing rebalance (pending) or a completed one (lastRebalanceBlock > 0)
        assertTrue(
            pending || lastRebalanceBlock > 0,
            "rebalance should have started or completed at least one batch"
        );

        // Vault strategy state should have a non-zero target asset when drift was detected
        (uint16 lastDriftBps,, Currency vaultTargetAsset) = vault.strategyState();
        console.log("vault lastDriftBps:", lastDriftBps);
        console.log("vault targetAsset:", Currency.unwrap(vaultTargetAsset));

        assertGt(lastDriftBps, 0, "drift bps should be > 0 after rebalance step");
        assertTrue(
            vaultTargetAsset == currencyWBTC || vaultTargetAsset == currencyWETH,
            "target asset should be one of the strategy assets"
        );

        // Capture vault balances after rebalance step
        uint256 usdcAfter = usdc.balanceOf(address(vault));
        uint256 wbtcAfter = wbtc.balanceOf(address(vault));
        uint256 wethAfter = weth.balanceOf(address(vault));

        console.log("Vault balances after rebalance:");
        console.log("USDC:", usdcAfter);
        console.log("WBTC:", wbtcAfter);
        console.log("WETH:", wethAfter);

        // We expect at least base asset and the target asset balances to change due to the swap
        if (vaultTargetAsset == currencyWBTC) {
            assertTrue(
                usdcAfter != usdcBefore || wbtcAfter != wbtcBefore,
                "USDC or WBTC balance should change for WBTC target"
            );
        } else if (vaultTargetAsset == currencyWETH) {
            assertTrue(
                usdcAfter != usdcBefore || wethAfter != wethBefore,
                "USDC or WETH balance should change for WETH target"
            );
        }
    }

    function testRebalanceStep_CompletesAllBatches() public {
        // Simulate price change on BTC to 50k USD 
        wbtcFeed.updateAnswer(50_000e8);

        // Capture initial balances
        uint256 usdcStart = usdc.balanceOf(address(vault));
        uint256 wbtcStart = wbtc.balanceOf(address(vault));
        uint256 wethStart = weth.balanceOf(address(vault));

        console.log("Vault balances at start of full rebalance:");
        console.log("USDC:", usdcStart);
        console.log("WBTC:", wbtcStart);
        console.log("WETH:", wethStart);

        // First rebalance step to start the window and execute first batch
        vault.rebalanceStep();

        // Record which asset the strategy decided to target
        (uint16 initialDriftBps, , Currency strategyTargetAsset) = vault.strategyState();

        (
            bool pending,
            uint32 nextBatchBlock,
            uint32 batchesRemaining,
            uint256 lastRebalanceBlock,
            Currency hookTargetAsset
        ) = hook.rebalanceState();

        console.log("Initial drift detected:");
        console.log("targetAsset:", MockERC20(Currency.unwrap(strategyTargetAsset)).symbol());
        console.log("initialDriftBps:", initialDriftBps);
        console.log("batchesRemaining after first step:", batchesRemaining);

        // Calculate and log initial portfolio state for debugging
        (uint256 totalValueStart, uint256[] memory valuesStart) = 
            vault.updatePricesHarness();
        uint256 targetValueStart = (totalValueStart * vault.targetAllocBps(strategyTargetAsset)) / 10_000;
        uint256 assetValueStart;
        for (uint256 i = 0; i < 3; i++) {
            if (vault.portfolioAssets(i) == strategyTargetAsset) {
                assetValueStart = valuesStart[i];
                break;
            }
        }
        int256 initialDev = int256(targetValueStart) - int256(assetValueStart);
        uint256 absDevStart = initialDev > 0 ? uint256(initialDev) : uint256(-initialDev);
        
        console.log("Initial portfolio analysis:");
        console.log("totalValue (1e18):", totalValueStart);
        console.log("targetValue for asset (1e18):", targetValueStart);
        console.log("assetValue (1e18):", assetValueStart);
        console.log("absDev (1e18):", absDevStart);
        
        (, uint16 batchSizeBps,) = vault.strategyConfig();
        uint256 expectedBatchValue = (absDevStart * batchSizeBps) / 10_000;
        if (expectedBatchValue > absDevStart || expectedBatchValue == 0) {
            expectedBatchValue = absDevStart;
        }
        console.log("expectedBatchValue per batch (1e18):", expectedBatchValue);
        console.log("total batches:", batchesRemaining + 1);
        
        // For buying (dev > 0), convert to base token amount
        if (initialDev > 0) {
            uint256 priceBase = vault.lastPriceInBase(currencyUSDC);
            uint256 expectedBaseAmountPerBatch = (expectedBatchValue * 1e6) / priceBase;
            uint256 expectedTotalBaseAmount = expectedBaseAmountPerBatch * (batchesRemaining + 1);
            console.log("expectedBaseAmount per batch (USDC raw):", expectedBaseAmountPerBatch);
            console.log("expectedBaseAmount per batch (USDC):", expectedBaseAmountPerBatch / 1e6);
            console.log("expectedTotalBaseAmount (all batches, USDC):", expectedTotalBaseAmount / 1e6);
        }

        // We expect a pending rebalance with at least 1 remaining batch
        assertTrue(pending, "rebalance should be pending after first step");
        assertGt(batchesRemaining, 0, "there should be remaining batches");
        assertEq(lastRebalanceBlock, 0, "lastRebalanceBlock should be zero until completion");
        assertTrue(
            hookTargetAsset == currencyWBTC || hookTargetAsset == currencyWETH,
            "hook targetAsset should be a strategy asset"
        );

        // Continue calling rebalanceStep until all batches are completed
        while (true) {
            // Move forward at least one block to satisfy both
            // - hook's nextBatchBlock spacing
            // - vault's minDriftCheckInterval
            (,, uint32 minDriftInterval) = vault.strategyConfig();

            vm.roll(block.number + minDriftInterval + 1 );

            vault.rebalanceStep();

            (
                bool p,
                uint32 nbb,
                uint32 br,
                uint256 lrb,
                Currency ta
            ) = hook.rebalanceState();

            pending = p;
            nextBatchBlock = nbb;
            batchesRemaining = br;
            lastRebalanceBlock = lrb;
            hookTargetAsset = ta;

            if (!pending) {
                break;
            }
        }

        console.log("Hook rebalance state after completing all batches:");
        console.log("pending:", pending);
        console.log("nextBatchBlock:", nextBatchBlock);
        console.log("batchesRemaining:", batchesRemaining);
        console.log("lastRebalanceBlock:", lastRebalanceBlock);
        console.log("hook targetAsset:", Currency.unwrap(hookTargetAsset));

        // At the end of full rebalance:
        assertFalse(pending, "rebalance should no longer be pending");
        assertEq(batchesRemaining, 0, "no batches should remain");
        assertEq(
            Currency.unwrap(hookTargetAsset),
            address(0),
            "hook targetAsset should be cleared"
        );
        assertGt(lastRebalanceBlock, 0, "lastRebalanceBlock should be set on completion");

        // Vault balances should have changed compared to start
        uint256 usdcEnd = usdc.balanceOf(address(vault));
        uint256 wbtcEnd = wbtc.balanceOf(address(vault));
        uint256 wethEnd = weth.balanceOf(address(vault));

        console.log("Vault balances after full rebalance:");
        console.log("USDC:", usdcEnd);
        console.log("WBTC:", wbtcEnd);
        console.log("WETH:", wethEnd);

        // Calculate actual changes
        int256 usdcChange = int256(usdcEnd) - int256(usdcStart);
        int256 wbtcChange = int256(wbtcEnd) - int256(wbtcStart);
        int256 wethChange = int256(wethEnd) - int256(wethStart);

        console.log("Balance changes (raw):");
        console.log("USDC change:", usdcChange);
        console.log("WBTC change:", wbtcChange);
        console.log("WETH change:", wethChange);
        
        // Compare actual vs expected
        if (strategyTargetAsset == currencyWETH && wethChange > 0) {
            console.log("Actual WETH received:", uint256(wethChange) / 1e18);
        } else if (strategyTargetAsset == currencyWBTC && wbtcChange > 0) {
            console.log("Actual WBTC received:", uint256(wbtcChange) / 1e8);
        }
        if (usdcChange < 0) {
            console.log("Actual USDC spent:", uint256(-usdcChange) / 1e6);
        }




        assertTrue(
            usdcEnd != usdcStart || wbtcEnd != wbtcStart || wethEnd != wethStart,
            "at least one asset balance should change after full rebalance"
        );

        // ==== Verify drift math: target asset allocation should be within minDriftBps ====

        // Pull strategy config and target allocation for the chosen asset
        (uint16 minDriftBps,,) = vault.strategyConfig();
        uint16 targetBps = vault.targetAllocBps(strategyTargetAsset);

        // Compute portfolio total value and target-asset value using vault's cached prices
        Currency[3] memory assetsArr = [currencyUSDC, currencyWBTC, currencyWETH];

        uint256 totalValue;
        uint256 assetValue;

        for (uint256 i = 0; i < assetsArr.length; i++) {
            Currency a = assetsArr[i];
            uint256 price = vault.lastPriceInBase(a);
            if (price == 0) continue;

            address token = Currency.unwrap(a);
            uint256 bal = IERC20(token).balanceOf(address(vault));

            // Normalize balance using vault's internal function
            uint256 normalizedBal = vault.normalizeBalanceHarness(token, bal);

            uint256 v = (normalizedBal * price) / 1e18;
            totalValue += v;
            if (a == strategyTargetAsset) {
                assetValue = v;
            }
        }

        // Compute post-rebalance drift of the target asset in BPS
        uint256 targetValue = (totalValue * targetBps) / 10_000;
        uint256 absDev = targetValue > assetValue
            ? targetValue - assetValue
            : assetValue - targetValue;
        uint16 driftBps = uint16((absDev * 10_000) / totalValue);

        console.log("post-rebalance driftBps for target asset:", driftBps);
        console.log("minDriftBps:", minDriftBps);

    }

    function testRebalanceStep_NoDriftDoesNothing() public {

    }

    function testRebalanceStep_RespectsMinDriftCheckInterval() public{
        
    }


    // ======= Test Hook BeforeSwap functionalities ==============





    // ======= Test Pools Swap Functionality ==============
    function test_WETH_USDC_Swap() public {
        // Swap WETH for USDC in the WETH/USDC pool

        // Arrange: mint WETH to this test contract and approve the manager
        uint256 wethAmountIn = 1e18; 
        weth.mint(address(this), wethAmountIn);
        weth.approve(address(manager), wethAmountIn);

        // Determine swap direction: zeroForOne = true means token0 -> token1
        bool zeroForOne = (wethPoolKey.currency0 == currencyWETH);

        // Prepare swap parameters: exact input swap
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(wethAmountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Record balances before swap
        uint256 wethBefore = weth.balanceOf(address(this));
        uint256 usdcBefore = usdc.balanceOf(address(this));
        console.log("weth Before:", wethBefore); 
        console.log("usdc Before:", usdcBefore); 

        // Act: perform the swap through the swapRouter
        swapRouter.swap(wethPoolKey, params, settings, bytes(""));

        // Assert: balances moved in expected direction
        uint256 wethAfter = weth.balanceOf(address(this));
        uint256 usdcAfter = usdc.balanceOf(address(this));

        console.log("weth After:",wethAfter);
        console.log("usdc After:",usdcAfter);


        // We should have spent some WBTC and received some USDC
        assertLt(wethAfter, wethBefore);
        assertGt(usdcAfter, usdcBefore);
    }

    function test_WBTC_USDC_Swap() public {
        // Swap WBTC for USDC in the WBTC/USDC pool

        // Arrange: mint WBTC to this test contract and approve the manager
        uint256 wbtcAmountIn = 0.1e8; // 0.1 WBTC (8 decimals)
        wbtc.mint(address(this), wbtcAmountIn);
        wbtc.approve(address(manager), wbtcAmountIn);

        // Determine swap direction: zeroForOne = true means token0 -> token1
        bool zeroForOne = (wbtcPoolKey.currency0 == currencyWBTC);

        // Prepare swap parameters: exact input swap
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(wbtcAmountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Record balances before swap
        uint256 wbtcBefore = wbtc.balanceOf(address(this));
        uint256 usdcBefore = usdc.balanceOf(address(this));
        console.log("wbtc Before:", wbtcBefore); 
        console.log("usdc Before:", usdcBefore); 

        // Act: perform the swap through the swapRouter
        swapRouter.swap(wbtcPoolKey, params, settings, bytes(""));

        // Assert: balances moved in expected direction
        uint256 wbtcAfter = wbtc.balanceOf(address(this));
        uint256 usdcAfter = usdc.balanceOf(address(this));

        console.log("wbtc After:",wbtcAfter);
        console.log("usdc After:",usdcAfter);


        // We should have spent some WBTC and received some USDC
        assertLt(wbtcAfter, wbtcBefore);
        assertGt(usdcAfter, usdcBefore);
    }
}