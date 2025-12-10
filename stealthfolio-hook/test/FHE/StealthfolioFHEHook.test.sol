// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import {Test} from "forge-std/Test.sol";


import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockV3Aggregator} from "@chainlink/local/src/data-feeds/MockV3Aggregator.sol";

// Uniswap v4 Imports
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

// Custom contracts
import {CalculatePrice} from "../../src/utils/CalculatePrice.sol";

// Fhenix imports
import {FHE, InEuint128, InEuint256, InEuint32,InEuint16, euint128, euint256, euint32,euint16} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

// Contracts to test
import {StealthfolioFHEHook} from "../../src/hooks/StealthfolioFHEHook.sol";
import {StealthfolioVaultFHE} from "../../src/StealthfolioVaultExecutorFHE.sol";

import "forge-std/console.sol";

// Minimal harness to expose internal functions for testing
contract StealthfolioVaultHarnessFHE is StealthfolioVaultFHE {
    constructor(
        IPoolManager _manager,
        StealthfolioFHEHook _hook
    ) StealthfolioVaultFHE(_manager, _hook) {}

    function normalizeBalanceHarness(
        address token,
        uint256 bal
    ) external view returns (uint256) {
        return _normalizeBalance(token, bal);
    }

    function updatePricesHarness()
        external
        returns (uint256 totalValue, uint256[] memory values)
    {
        return _updatePrices();
    }



}

contract StealthfolioFHEHookTest is Test, CoFheTest, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    StealthfolioFHEHook hook;
    StealthfolioVaultHarnessFHE vault;

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

        // FHE Logs
        setLog(true);

        uint8 usdcDecimals = 6;
        uint8 wbtcDecimals = 8;
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
        deployCodeTo(
            "StealthfolioFHEHook.sol",
            abi.encode(manager),
            hookAddress
        );
        hook = StealthfolioFHEHook(hookAddress);

        // Deploy vault
        vault = new StealthfolioVaultHarnessFHE(manager, hook);

        // Configure hook
        hook.configureHook(
            address(vault),
            currencyUSDC,
            10, // rebalanceCooldown: 10 blocks
            100 // rebalanceMaxDuration: 100 blocks
        );

        // Mint tokens to vault
        usdc.mint(address(vault), 1000000e6); // 1M USDC
        wbtc.mint(address(vault), 10e8); // 10 WBTC
        weth.mint(address(vault), 100e18); // 100 WETH

        // Calculate BTCUSD SqrtPrice

        (
            Currency token0,
            Currency token1,
            uint160 sqrtPriceBTC_USDC
        ) = CalculatePrice.computeInitSqrtPrice(
                currencyWBTC,
                currencyUSDC,
                wbtcDecimals,
                usdcDecimals,
                100_000
            );

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
        (token0, token1, sqrtPriceWETH_USDC) = CalculatePrice
            .computeInitSqrtPrice(
                currencyWETH,
                currencyUSDC,
                wethDecimals,
                usdcDecimals,
                3_000
            );

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

        int24 currentTickBTCUSDC = TickMath.getTickAtSqrtPrice(
            sqrtPriceBTC_USDC
        );

        // Tick Math calculation for WETH / USDC Pair
        int24 currentTickWETHUSDC = TickMath.getTickAtSqrtPrice(
            sqrtPriceWETH_USDC
        );

        console.log("BTC Sqrt Price:", sqrtPriceBTC_USDC);
        console.log("BTC current Tick: ", currentTickBTCUSDC);
        console.log("");
        console.log("WETH Sqrt Price:", sqrtPriceWETH_USDC);
        console.log("WETH Current Tick:", currentTickWETHUSDC);

        int24 tickLowerBTCUSDC = (currentTickBTCUSDC / TICK_SPACING - 1) *
            TICK_SPACING;
        int24 tickUpperBTCUSDC = (currentTickBTCUSDC / TICK_SPACING + 1) *
            TICK_SPACING;

        int24 tickLowerWETHUSDC = (currentTickWETHUSDC / TICK_SPACING - 10) *
            TICK_SPACING;
        int24 tickUpperWETHUSDC = (currentTickWETHUSDC / TICK_SPACING + 10) *
            TICK_SPACING;

        uint160 sqrtPriceLowerX96BTCUSD = TickMath.getSqrtPriceAtTick(
            tickLowerBTCUSDC
        );
        uint160 sqrtPriceUpperX96BTCUSD = TickMath.getSqrtPriceAtTick(
            tickUpperBTCUSDC
        );

        uint160 sqrtPriceLowerX96WETHUSD = TickMath.getSqrtPriceAtTick(
            tickLowerWETHUSDC
        );
        uint160 sqrtPriceUpperX96WETHUSD = TickMath.getSqrtPriceAtTick(
            tickUpperWETHUSDC
        );

        uint256 amount0USDCDesired = 1_000_000e6; // 1M USDC
        uint256 amount1WBTCDesired = 10e8; // 10 WBTC

        uint256 amountUSDCDesired = 300_000e6; // 300,000 in USDC
        uint256 amount1WETHDesired = 100e18; // 100 WETH

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

        (uint256 amount0, uint256 amount1) = LiquidityAmounts
            .getAmountsForLiquidity(
                sqrtPriceBTC_USDC,
                sqrtPriceLowerX96BTCUSD,
                sqrtPriceUpperX96BTCUSD,
                liquidityBTCUSD
            );

        console.log("Amount 0 BTCUSD:", amount0);
        console.log("Amount 1 BTCUSD:", amount1);

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceWETH_USDC,
            sqrtPriceLowerX96WETHUSD,
            sqrtPriceUpperX96WETHUSD,
            liquidityWETHUSD
        );

        console.log("Amount 0 WETHUSD:", amount0);
        console.log("Amount 1 WETHUSD:", amount1);

        modifyLiquidityRouter.modifyLiquidity(
            wbtcPoolKey,
            liqParamsBTC,
            bytes("")
        );
        modifyLiquidityRouter.modifyLiquidity(
            wethPoolKey,
            liqParamsWETH,
            bytes("")
        );

        
        // Configure encrypted strategy for the vault 
        uint32 minDriftBps = 100;        // 1%
        uint32 batchSizeBps = 2_500;     // 25%
        uint32 minDriftCheckInterval = 1;



        InEuint32 memory _encMinDriftBps = createInEuint32(
            minDriftBps,
            address(this)
        );

        InEuint32 memory _encBatchSizeBps = createInEuint32(
            batchSizeBps,
            address(this)
        );

        InEuint32 memory _encMinDriftCheckInterval = createInEuint32(
            minDriftCheckInterval,
            address(this)
        );

        // Configure strategy on harness with USDC as base asset
        vault.configureEncryptedStrategy(
            _encMinDriftBps, // minDriftBps: 1%
            _encBatchSizeBps, // batchSizeBps: 25%
            _encMinDriftCheckInterval // minDriftCheckInterval: 1 block
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

        InEuint16[] memory encryptedBpsInputs = new InEuint16[](3); 

        for (uint16 i = 0; i < bps.length; i++){
            InEuint16 memory _encBps = createInEuint16(bps[i] ,address(this));
            encryptedBpsInputs[i] = _encBps; 
        }
        

        vault.setEncryptedPortfolioTargets(assets, encryptedBpsInputs);
        // Set price feeds
        vault.setPriceFeed(currencyUSDC, address(usdcFeed));
        vault.setPriceFeed(currencyWBTC, address(wbtcFeed));
        vault.setPriceFeed(currencyWETH, address(wethFeed));


        // Time fast forward to let the decryption finish
        vm.warp(block.timestamp + 10);
    }

    // ======= Test Hook BeforeSwap functionalities with Fhenix encrypted guardrails ==============

    // Test encrypted Vol Bands
    function testSetEncryptedVolBands() public {
        // 1) Set a tight vol band around the *current* WETH/USDC price
        PoolId poolId = wethPoolKey.toId();

        (uint160 currentSqrtPriceX96, , , ) = manager.getSlot0(poolId);

        // Very tight band, e.g. 10 bps (~0.1%)
        uint16 widthBps = 10;

        // --- NEW: encrypt center + width using CoFheTest helpers ---

        // center is uint160, but InEuint256 works with uint256
        InEuint256 memory encCenter = createInEuint256(
            uint256(currentSqrtPriceX96),
            address(this)
        );

        // widthBps is uint16, but InEuint32 expects uint32
        InEuint32 memory encWidth = createInEuint32(
            uint32(widthBps),
            address(this)
        );

        // Call encrypted setter on the hook
        hook.setEncryptedVolBand(wethPoolKey, encCenter, encWidth);

        // 3) Assert encrypted value really represents `limit`
        (
            euint256 encryptedCenterSqrtPriceX96,
            euint32 encryptedWidthBps,
            bool enabled
        ) = hook.volBands(wethPoolKey.toId());
        assertHashValue(encryptedWidthBps, 10);
        assertHashValue(
            euint256.unwrap(encryptedCenterSqrtPriceX96),
            currentSqrtPriceX96
        );
    }

    function testVolBand_AllowsSwapInsideBandAndRevertsOutside() public {
        // 1) Set a tight vol band around the *current* WETH/USDC price
        PoolId poolId = wethPoolKey.toId();

        (uint160 currentSqrtPriceX96, , , ) = manager.getSlot0(poolId);

        // Very tight band, e.g. 10 bps (~0.1%)
        uint16 widthBps = 10;

        // --- NEW: encrypt center + width using CoFheTest helpers ---

        // center is uint160, but InEuint256 works with uint256
        InEuint256 memory encCenter = createInEuint256(
            uint256(currentSqrtPriceX96),
            address(this)
        );

        // widthBps is uint16, but InEuint32 expects uint32
        InEuint32 memory encWidth = createInEuint32(
            uint32(widthBps),
            address(this)
        );

        // Call encrypted setter on the hook
        hook.setEncryptedVolBand(wethPoolKey, encCenter, encWidth);

        // IMPORTANT: give the mock time to "finish" decryption
        vm.warp(block.timestamp + 20);

        // 2) First swap: should pass (price initially inside band)

        bool zeroForOne = (wethPoolKey.currency0 == currencyWETH);
        uint256 largeAmountIn = 50e18; // 50 WETH (big vs your liquidity)

        weth.mint(address(this), largeAmountIn);
        weth.approve(address(manager), largeAmountIn);

        SwapParams memory params1 = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(largeAmountIn), // exact input
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // First swap should NOT revert
        swapRouter.swap(wethPoolKey, params1, settings, bytes(""));

        // 3) Second swap: now price likely moved significantly.
        // If current price is outside band, it should revert with VOL_BAND_BREACH.

        uint256 smallAmountIn = 1e18; // 1 WETH

        weth.mint(address(this), smallAmountIn);
        weth.approve(address(manager), smallAmountIn);

        SwapParams memory params2 = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(smallAmountIn),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        vm.expectRevert();
        swapRouter.swap(wethPoolKey, params2, settings, bytes(""));
    }

    function testVolBand_AllowsSwapsWhenInsideBand() public {
        PoolId poolId = wethPoolKey.toId();
        (uint160 currentSqrtPriceX96, , , ) = manager.getSlot0(poolId);

        // Wide band: +/- 50%  (5_000 bps)
        uint32 widthBps = 5_000;

        // --- NEW: encrypt center + width ---
        InEuint256 memory encCenter = createInEuint256(
            uint256(currentSqrtPriceX96),
            address(this)
        );

        InEuint32 memory encWidth = createInEuint32(widthBps, address(this));

        hook.setEncryptedVolBand(wethPoolKey, encCenter, encWidth);

        // Let mock decryption complete
        vm.warp(block.timestamp + 20);

        bool zeroForOne = (wethPoolKey.currency0 == currencyWETH);
        uint256 amountIn = 1e18;

        weth.mint(address(this), amountIn);
        weth.approve(address(manager), amountIn);

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Should not revert
        swapRouter.swap(wethPoolKey, params, settings, bytes(""));
    }

    // Test encrypted Max Trades

    function testSetEncryptedMaxTrade() public {
        uint128 limit = 1_000e6; // 1,000 units, whatever decimals

        // 1) Create encrypted input for `user`
        InEuint128 memory encLimit = createInEuint128(limit, address(this));

        hook.setEncryptedMaxTradeGuard(wbtcPoolKey, encLimit);

        // 3) Assert encrypted value really represents `limit`
        (euint128 encryptedMaxTrade, bool enabled) = hook.maxTradeGuards(
            wbtcPoolKey.toId()
        );
        assertHashValue(encryptedMaxTrade, limit);
    }

    // Test the encypted Max Trade Guard
    function testEncryptedMaxTradeGuard_RevertsWhenExceedingLimit() public {
        // Enable max trade guard on WETH/USDC pool
        uint128 maxAmount = 5e18; // 5 WETH

        // 1) Create encrypted input for `user`
        InEuint128 memory encLimit = createInEuint128(maxAmount, address(this));
        hook.setEncryptedMaxTradeGuard(wethPoolKey, encLimit);

        // Time fast forward to let the decryption finish
        vm.warp(block.timestamp + 20);

        bool zeroForOne = (wethPoolKey.currency0 == currencyWETH);

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // --- 1) Trade slightly below the limit: should pass ---
        uint256 safeAmountIn = 4e18;

        weth.mint(address(this), safeAmountIn);
        weth.approve(address(manager), safeAmountIn);

        SwapParams memory paramsSafe = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(safeAmountIn),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(wethPoolKey, paramsSafe, settings, bytes(""));

        // --- 2) Trade above the limit: should revert with "Max Trade" ---
        uint256 tooLargeAmountIn = 6e18;

        weth.mint(address(this), tooLargeAmountIn);
        weth.approve(address(manager), tooLargeAmountIn);

        SwapParams memory paramsTooLarge = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(tooLargeAmountIn),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        vm.expectRevert();
        swapRouter.swap(wethPoolKey, paramsTooLarge, settings, bytes(""));
    }

    // Test Toxic Flow config
    function testSetEncryptedToxicFlowGuard() public {

        // Configure toxic flow for WETH/USDC (encrypted thresholds)
        uint32 windowBlocks = 20;
        uint32 maxSameDirLargeTrades = 2;
        uint256 minLargeTradeAmount = 1e18; // 1 WETH

        // Encrypt thresholds using CoFheTest helpers

        InEuint32 memory encWindowBlocks = createInEuint32(
            windowBlocks,
            address(this)
        );

        InEuint32 memory encMaxSameDir = createInEuint32(
            maxSameDirLargeTrades,
            address(this)
        );

        InEuint256 memory encMinLarge = createInEuint256(
            minLargeTradeAmount,
            address(this)
        );

        // Call encrypted setter on the hook
        hook.setEncryptedToxicFlowConfig(
            wethPoolKey,
            encWindowBlocks,
            encMaxSameDir,
            encMinLarge
        );


        // 3) Assert encrypted value really represents `limit`
       (bool enabled , 
        euint32 storedEncWindowBlocks, 
        euint32  storedEncMaxSameDirLargeTrades, 
        euint256 storedEncMinLargeTradeAmount ) = hook.toxicConfigs(
            wethPoolKey.toId()
        );

        assertHashValue(storedEncWindowBlocks, 20);
        assertHashValue(storedEncMaxSameDirLargeTrades, 2);
        assertHashValue(euint256.unwrap(storedEncMinLargeTradeAmount), 1e18);




    }
    function testToxicFlowGuard_BlocksTooManySameDirectionLargeTrades() public {
        // (Optional) if your toxic guard only runs during rebalancing
        vault.rebalanceStep();

        // Configure toxic flow for WETH/USDC (encrypted thresholds)
        uint32 windowBlocks = 20;
        uint32 maxSameDirLargeTrades = 2;
        uint256 minLargeTradeAmount = 1e18; // 1 WETH

        // Encrypt thresholds using CoFheTest helpers

        InEuint32 memory encWindowBlocks = createInEuint32(
            windowBlocks,
            address(this)
        );

        InEuint32 memory encMaxSameDir = createInEuint32(
            maxSameDirLargeTrades,
            address(this)
        );

        InEuint256 memory encMinLarge = createInEuint256(
            minLargeTradeAmount,
            address(this)
        );

        // Call encrypted setter on the hook
        hook.setEncryptedToxicFlowConfig(
            wethPoolKey,
            encWindowBlocks,
            encMaxSameDir,
            encMinLarge
        );

        // Give the mock time to “finish” decryption
        vm.warp(block.timestamp + 20);

        bool zeroForOne = (wethPoolKey.currency0 == currencyWETH);
        uint256 largeAmountIn = 2e18; // 2 WETH, above minLargeTradeAmount

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Helper: do a single large swap in same direction
        for (uint256 i = 0; i < 2; i++) {
            weth.mint(address(this), largeAmountIn);
            weth.approve(address(manager), largeAmountIn);

            SwapParams memory params = SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(largeAmountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            });

            // First 2 large trades should pass
            swapRouter.swap(wethPoolKey, params, settings, bytes(""));
        }

        // Third large trade in same direction, in same block window, should revert
        weth.mint(address(this), largeAmountIn);
        weth.approve(address(manager), largeAmountIn);

        SwapParams memory paramsThird = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(largeAmountIn),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        vm.expectRevert();
        swapRouter.swap(wethPoolKey, paramsThird, settings, bytes(""));
    }
}
