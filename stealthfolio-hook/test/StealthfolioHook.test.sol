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


contract StealthfolioTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    StealthfolioHook hook;
    StealthfolioVault vault;
    
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
        vault = new StealthfolioVault(manager, hook);
        
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

        (Currency token0, Currency token1, uint160 sqrtPriceBTC_USDC) = 
                            CalculatePrice.computeInitSqrtPrice(currencyWBTC, 
                            currencyUSDC, 
                            wbtcDecimals, 
                            usdcDecimals, 100_000); 


        console.log("Token 0: ", MockERC20(Currency.unwrap(token0)).symbol()); 

        
        // Create pools
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
        weth.mint(address(this), 100e18);
        
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
        

        int24 tickLowerWETHUSDC = (currentTickWETHUSDC / TICK_SPACING - 1) * TICK_SPACING;
        int24 tickUpperWETHUSDC = (currentTickWETHUSDC / TICK_SPACING + 1) * TICK_SPACING;

        uint160 sqrtPriceLowerX96BTCUSD = TickMath.getSqrtPriceAtTick(tickLowerBTCUSDC);
        uint160 sqrtPriceUpperX96BTCUSD = TickMath.getSqrtPriceAtTick(tickUpperBTCUSDC);

        uint160 sqrtPriceLowerX96WETHUSD = TickMath.getSqrtPriceAtTick(tickLowerWETHUSDC);
        uint160 sqrtPriceUpperX96WETHUSD = TickMath.getSqrtPriceAtTick(tickUpperWETHUSDC);


        uint256 amount0USDCDesired = 1_000_000e6; // 1M USDC
        uint256 amount1WBTCDesired = 10e8;        // 10 WBTC    


        uint256 amountUSDCDesired = 30_000e6; // 30,000 in USDC
        uint256 amount1WETHDesired = 10e18;        // 10 WETH    


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


        // Add liquidity using modifyLiquidityRouter
        ModifyLiquidityParams memory liqParams = ModifyLiquidityParams({
            tickLower: tickLowerBTCUSDC,
            tickUpper: tickUpperBTCUSDC,
            liquidityDelta: int256(uint256(liquidityBTCUSD)),
            salt: bytes32(0)
        });

        // Add liquidity using modifyLiquidityRouter
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
        
        modifyLiquidityRouter.modifyLiquidity(wbtcPoolKey, liqParams, bytes(""));
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