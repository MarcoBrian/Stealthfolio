// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";


import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockV3Aggregator} from "@chainlink/local/src/data-feeds/MockV3Aggregator.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey, PoolIdLibrary} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

//
import {StealthfolioVaultFHE} from "../../src/StealthfolioVaultExecutorFHE.sol";
import {StealthfolioFHEHook} from "../../src/hooks/StealthfolioFHEHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CalculatePrice} from "../../src/utils/CalculatePrice.sol";

// Fhenix imports
import {FHE, InEuint128, InEuint256, InEuint32, InEuint16, euint128, euint256, euint32, euint16} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

import "forge-std/console.sol"; 

contract StealthfolioVaultHarnessFHE is StealthfolioVaultFHE {
    using CurrencyLibrary for Currency;

    constructor(IPoolManager _manager, StealthfolioFHEHook _hook)
        StealthfolioVaultFHE(_manager, _hook)
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



    /// @dev Expose _computeBatchParams for testing
    function computeBatchParamsHarness()
        external
        view
        returns (BatchParams memory)
    {
        return _computeBatchParams();
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

contract StealthfolioVaultExecutorFHETest is Test, CoFheTest, Deployers {
    using CurrencyLibrary for Currency;

    StealthfolioVaultHarnessFHE vault;
    StealthfolioFHEHook hook;

    PoolKey wbtcPoolKey;
    PoolKey wethPoolKey;
    PoolId wbtcPoolId;
    PoolId wethPoolId;

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;

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
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        uint8 usdcDecimals = 6 ; 
        uint8 wbtcDecimals = 8 ; 
        uint8 wethDecimals = 18; 

        // Deploy hook
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("StealthfolioFHEHook.sol", abi.encode(manager), hookAddress);
        hook = StealthfolioFHEHook(hookAddress);

        

        vault = new StealthfolioVaultHarnessFHE(manager, hook);

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

        // Configure hook
        hook.configureHook(
            address(vault),
            currencyUSDC,
            10, // rebalanceCooldown: 10 blocks
            100 // rebalanceMaxDuration: 100 blocks
        );

        // Configure strategy on harness with USDC as base asset
        vault.configureEncryptedStrategy(
            _encMinDriftBps, // minDriftBps: 1%
            _encBatchSizeBps, // batchSizeBps: 25%
            _encMinDriftCheckInterval // minDriftCheckInterval: 1 block
        );

         


        // Calculate BTCUSD SqrtPrice

        (Currency token0, Currency token1, uint160 sqrtPriceBTC_USDC) = 
                            CalculatePrice.computeInitSqrtPrice(currencyWBTC, 
                            currencyUSDC, 
                            wbtcDecimals, 
                            usdcDecimals, 100_000); 

        
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

        // Mint balances to vault so there is some non-zero portfolio value
        usdc.mint(address(vault), 500_000e6); // 500k USDC
        wbtc.mint(address(vault), 5e8); // 5 WBTC
        weth.mint(address(vault), 50e18); // 50 WETH


        // Time fast forward to let the decryption finish
        vm.warp(block.timestamp + 10);
    }


    // ======================
    // Configuration Tests for the Vault 
    // ======================    

    function testConfigureStrategy_SetsFieldsCorrectly() public {

        (euint32 encryptedMinDriftBps, euint32 encryptedBatchSizeBps, euint32 encryptedMinDriftCheckInterval, bool enabled ) = vault.encryptedStrategyConfig(); 

        assertHashValue(encryptedMinDriftBps, 100); 
        assertHashValue(encryptedBatchSizeBps, 2_500); 
        assertHashValue(encryptedMinDriftCheckInterval, 1); 
        assertTrue(enabled, "Not Enabled ");


        (uint16 lastDriftBpsOutput, uint32 lastDriftCheckBlockOutput, Currency targetAssetOutput) = vault.strategyState(); 
        assertEq(lastDriftBpsOutput, 0);
        assertEq(lastDriftCheckBlockOutput, 0); 
        assertEq(Currency.unwrap(targetAssetOutput),address(0)); 

    }

    function testSetPortfolioTargets_ValidInputStoresState() public {
        

        // Set portfolio targets: 50% USDC, 25% WBTC, 25% WETH
        Currency[] memory assets = new Currency[](3);
        assets[0] = currencyUSDC;
        assets[1] = currencyWBTC;
        assets[2] = currencyWETH;

        uint16[] memory bps = new uint16[](3);
        bps[0] = 5_000; // 50% USDC
        bps[1] = 2_500; // 25% WBTC
        bps[2] = 2_500; // 25% WETH

        InEuint16[] memory encryptedBpsInputs = new InEuint16[](3); 

        for (uint16 i = 0; i < bps.length; i++){
            InEuint16 memory _encBps = createInEuint16(bps[i] ,address(this));
            encryptedBpsInputs[i] = _encBps; 
        }



        vault.setEncryptedPortfolioTargets(assets, encryptedBpsInputs);

        // Assert: portfolioAssets.length == 3
        assertEq(Currency.unwrap(vault.portfolioAssets(0)), Currency.unwrap(currencyUSDC), "portfolioAssets[0] should be USDC");
        assertEq(Currency.unwrap(vault.portfolioAssets(1)), Currency.unwrap(currencyWBTC), "portfolioAssets[1] should be WBTC");
        assertEq(Currency.unwrap(vault.portfolioAssets(2)), Currency.unwrap(currencyWETH), "portfolioAssets[2] should be WETH");

        // Assert: targetAllocBps values are correct
        euint16 tBps_usdc = vault.encryptedTargetAllocBps(currencyUSDC); 
        assertHashValue(tBps_usdc,5_000 ); 

        euint16 tBps_wbtc = vault.encryptedTargetAllocBps(currencyWBTC); 
        assertHashValue(tBps_wbtc,2_500 ); 

        euint16 tBps_weth = vault.encryptedTargetAllocBps(currencyWETH); 
        assertHashValue(tBps_weth, 2_500 ); 


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


    // // ======================
    // // Configuration Tests for the Vault  - Negative tests
    // // ======================


    function testSetPortfolioTargets_RevertsIfTotalBpsNot10000() public {
        

        // Set portfolio targets with invalid total: 50% USDC, 30% WBTC, 25% WETH = 10,500 bps (should be 10,000)
        Currency[] memory assets = new Currency[](3);
        assets[0] = currencyUSDC;
        assets[1] = currencyWBTC;
        assets[2] = currencyWETH;

        uint16[] memory bps = new uint16[](3);
        bps[0] = 5_000; // 50% USDC
        bps[1] = 3_000; // 30% WBTC
        bps[2] = 2_500; // 25% WETH (total = 10,500, not 10,000)

        InEuint16[] memory encryptedBpsInputs = new InEuint16[](3); 

        for (uint16 i = 0; i < bps.length; i++){
            InEuint16 memory _encBps = createInEuint16(bps[i] ,address(this));
            encryptedBpsInputs[i] = _encBps; 
        }

        vault.setEncryptedPortfolioTargets(assets, encryptedBpsInputs);

        // Time fast forward to let the decryption finish
        vm.warp(block.timestamp + 5);

        vm.expectRevert("TOTAL_BPS_NEQ_100");
        vault.rebalanceStep(); 
        



    }

    function testSetPortfolioTargets_RevertsIfBaseNotInPortfolio() public {
        
        // Set portfolio targets without baseAsset (only WBTC and WETH)
        Currency[] memory assets = new Currency[](2);
        assets[0] = currencyWBTC;
        assets[1] = currencyWETH;

        uint16[] memory bps = new uint16[](2);
        bps[0] = 5_000; // 50% WBTC
        bps[1] = 5_000; // 50% WETH

        InEuint16[] memory encryptedBpsInputs = new InEuint16[](2); 

        for (uint16 i = 0; i < bps.length; i++){
            InEuint16 memory _encBps = createInEuint16(bps[i] ,address(this));
            encryptedBpsInputs[i] = _encBps; 
        }

        vm.expectRevert("BASE_NOT_IN_PORTFOLIO");

        vault.setEncryptedPortfolioTargets(assets, encryptedBpsInputs);
    }

    // Remove this test since we cannot check BPS zero for encrypted
    // function testSetPortfolioTargets_RevertsIfBpsZero() public {

    //     // Set portfolio targets with zero BPS for one asset
    //     Currency[] memory assets = new Currency[](3);
    //     assets[0] = currencyUSDC;
    //     assets[1] = currencyWBTC;
    //     assets[2] = currencyWETH;

    //     uint16[] memory bps = new uint16[](3);
    //     bps[0] = 5_000; // 50% USDC
    //     bps[1] = 0; // 0% WBTC (should revert)
    //     bps[2] = 5_000; // 50% WETH

    //     InEuint16[] memory encryptedBpsInputs = new InEuint16[](3); 

    //     for (uint16 i = 0; i < bps.length; i++){
    //         InEuint16 memory _encBps = createInEuint16(bps[i] ,address(this));
    //         encryptedBpsInputs[i] = _encBps; 
    //     }

    //     vm.expectRevert("BPS_ZERO");
    //     vault.setEncryptedPortfolioTargets(assets, encryptedBpsInputs);
    // }

    function testSetPortfolioTargets_RevertsIfAssetZero() public {
        
        // Set portfolio targets with zero address for one asset
        Currency[] memory assets = new Currency[](3);
        assets[0] = currencyUSDC;
        assets[1] = Currency.wrap(address(0)); // Zero address (should revert)
        assets[2] = currencyWETH;

        uint16[] memory bps = new uint16[](3);
        bps[0] = 5_000; // 50% USDC
        bps[1] = 2_500; // 25% (invalid asset)
        bps[2] = 2_500; // 25% WETH

        InEuint16[] memory encryptedBpsInputs = new InEuint16[](3); 

        for (uint16 i = 0; i < bps.length; i++){
            InEuint16 memory _encBps = createInEuint16(bps[i] ,address(this));
            encryptedBpsInputs[i] = _encBps; 
        }

        vm.expectRevert("ASSET_ZERO");
        vault.setEncryptedPortfolioTargets(assets, encryptedBpsInputs);
    }

    function testSetPortfolioTargets_RevertsIfArraysLengthMismatch() public {
        // Set portfolio targets with mismatched array lengths
        Currency[] memory assets = new Currency[](3);
        assets[0] = currencyUSDC;
        assets[1] = currencyWBTC;
        assets[2] = currencyWETH;

        uint16[] memory bps = new uint16[](2); // Only 2 BPS values for 3 assets
        bps[0] = 5_000;
        bps[1] = 5_000;

         InEuint16[] memory encryptedBpsInputs = new InEuint16[](2); 

        for (uint16 i = 0; i < bps.length; i++){
            InEuint16 memory _encBps = createInEuint16(bps[i] ,address(this));
            encryptedBpsInputs[i] = _encBps; 
        }

        vm.expectRevert("ASSETS_BPS_LEN");
        vault.setEncryptedPortfolioTargets(assets, encryptedBpsInputs);
    }


    // // ======= Test functions functionality =========

    function test_findMaxDeviation() public {
        (Currency maxAsset, uint256 maxAbsDev) = vault.findMaxDeviationHarness(); 
        console.log("MaxAsset:", MockERC20(Currency.unwrap(maxAsset)).symbol()); 
        console.log("MaxAbsDev (USD):", maxAbsDev / 1e18 ); 
    }


    // // ======================
    // // Batch Computation Tests - computeBatchParams() 
    // // ======================
    
    
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
         // --- Arrange: make WBTC strongly overweight vs target ---
        // - baseAsset = USDC
        // - portfolioAssets = [USDC, WBTC, WETH]
        // - targetAllocBps for each

        // Push WBTC value way up so its share is > target share.
        wbtcFeed.updateAnswer(200_000e8);   // 1 WBTC = 200,000 USDC
        wethFeed.updateAnswer(1_000e8);     // 1 WETH = 1,000 USDC
        usdcFeed.updateAnswer(1e8);         // 1 USDC = 1 USDC

        // Update prices & compute drift; this will also set strategyState.targetAsset
        StealthfolioVaultFHE.DriftResult memory drift =
            vault.updatePricesAndCheckDriftHarness();

        // We expect:
        // - drift.shouldRebalance == true
        // - targetAsset == WBTC, because WBTC is now overweight
        assertTrue(drift.shouldRebalance, "shouldRebalance must be true");
        assertEq(
            Currency.unwrap(drift.targetAsset),
            address(wbtc),
            "WBTC should be selected as targetAsset for rebalance"
        );

        // --- Act: compute batch params from strategy state and cached prices ---

        StealthfolioVaultFHE.BatchParams memory params =
            vault.computeBatchParamsHarness();

        // --- Assert: direction + amount semantics ---

        // Because WBTC is overweight, we should be SELLING WBTC for base
        // => input token must be WBTC, so amountSpecified is in WBTC units.
        // For an overweight asset:
        //  - if asset is token0 → zeroForOne == true, input is token0 (asset)
        //  - if asset is token1 → zeroForOne == false, input is token1 (asset)

        Currency asset = drift.targetAsset;
        bool assetIsToken0 = (asset == params.poolKey.currency0);

        if (assetIsToken0) {
            // WBTC is token0, overweight => SELL token0 → token1
            assertTrue(params.zeroForOne, "asset token0 overweight, zeroForOne must be true");
        } else {
            // WBTC is token1, overweight => SELL token1 → token0
            assertFalse(params.zeroForOne, "asset token1 overweight, zeroForOne must be false");
        }

        // And we should NEVER try to sell more WBTC than the vault actually has.
        uint256 wbtcBal = wbtc.balanceOf(address(vault));
        assertLe(
            params.amountSpecified,
            wbtcBal,
            "amountSpecified should not exceed vault WBTC balance"
        );

        // Optional: sanity check that we are actually moving a non-zero amount.
        assertGt(params.amountSpecified, 0, "amountSpecified should be > 0 for overweight WBTC");
            
    }

    function  testComputeBatchParams_AssetUnderweight_AmountSpecifiedUsesBaseBalance() public {
        // --- Arrange: make WBTC underweight vs target ---

        // Make WBTC cheap and USDC/WETH relatively more valuable,
        // so WBTC's share of total value is below its target.
        wbtcFeed.updateAnswer(1_000e8);     // 1 WBTC = 1,000 USDC
        wethFeed.updateAnswer(3_000e8);     // 1 WETH = 3,000 USDC
        usdcFeed.updateAnswer(1e8);         // 1 USDC = 1 USDC

        // Recompute drift
        StealthfolioVaultFHE.DriftResult memory drift =
            vault.updatePricesAndCheckDriftHarness();

        // We expect a rebalance, with WBTC as the underweight asset
        assertTrue(drift.shouldRebalance, "shouldRebalance must be true");
        assertEq(
            Currency.unwrap(drift.targetAsset),
            address(wbtc),
            "WBTC should be targetAsset (underweight)"
        );

        // --- Act: compute batch params ---

        StealthfolioVaultFHE.BatchParams memory params =
            vault.computeBatchParamsHarness();

        // --- Assert: direction + amount semantics ---

        // Underweight asset => BUY asset with base
        // So input token must be baseAsset (USDC).
        Currency base = vault.baseAsset();
        Currency asset = drift.targetAsset;
        bool assetIsToken0 = (asset == params.poolKey.currency0);

        // Our swap direction logic says:
        //  - dev > 0 (underweight)
        //  - if assetIsToken0 → zeroForOne = false → token1 (base) → token0 (asset)
        //  - if assetIsToken1 → zeroForOne = true  → token0 (base) → token1 (asset)
        if (assetIsToken0) {
            assertFalse(
                params.zeroForOne,
                "asset token0 underweight, zeroForOne must be false (base -> asset)"
            );
            // zeroForOne = false: input is token1, so token1 must be base
            assertEq(
                Currency.unwrap(params.poolKey.currency1),
                Currency.unwrap(base),
                "token1 must be base asset when buying asset token0"
            );
        } else {
            assertTrue(
                params.zeroForOne,
                "asset token1 underweight => zeroForOne must be true (base => asset)"
            );
            // zeroForOne = true: input is token0, so token0 must be base
            assertEq(
                Currency.unwrap(params.poolKey.currency0),
                Currency.unwrap(base),
                "token0 must be base asset when buying asset token1"
            );
        }

        // And the batch size must not exceed available base balance.
        uint256 baseBal = IERC20(Currency.unwrap(base)).balanceOf(address(vault));
        assertLe(
            params.amountSpecified,
            baseBal,
            "amountSpecified should not exceed vault base balance"
        );

        assertGt(
            params.amountSpecified,
            0,
            "amountSpecified should be > 0 when asset is underweight"
        );
    }
    

    function testComputeBatchParams_ZeroDeviation_ReturnsZeroAmount() public {
        // --- Arrange: configure a single-asset portfolio = 100% baseAsset ---

        Currency base = currencyUSDC; // assuming you have this in your test setUp

        // Override portfolio to [base] with 100% allocation
        Currency[] memory assets = new Currency[](1);
        assets[0] = base;

        uint16[] memory bps = new uint16[](1); 
        bps[0] = 10_000; // 100%

         InEuint16[] memory encryptedBpsInputs = new InEuint16[](1); 

        for (uint16 i = 0; i < bps.length; i++){
            InEuint16 memory _encBps = createInEuint16(bps[i] ,address(this));
            encryptedBpsInputs[i] = _encBps; 
        }

        // Need to be owner in tests
        vault.setEncryptedPortfolioTargets(assets, encryptedBpsInputs);
        vault.setPriceFeed(base, address(usdcFeed));
        vm.warp(block.timestamp + 5); 

        // Ensure we have some base balance in the vault
        // (you probably already deposited in setUp; if not, do it here)
        // usdc.mint(address(vault), 1_000_000e6); // if needed

        // Update prices so lastPriceInBase[base] is non-zero
        StealthfolioVaultFHE.DriftResult memory drift = vault.updatePricesAndCheckDriftHarness();

        assertFalse(drift.shouldRebalance, "Should not rebalance");


    }



    // ======================
    // Drift Detection Test - updatePricesAndCheckDrift()
    // ======================

    function testUpdatePricesAndCheckDrift_RevertsIfStrategyConfigured() public {
        // Create a fresh vault without configuring strategy
        StealthfolioVaultHarnessFHE freshVault = new StealthfolioVaultHarnessFHE(manager, hook);
        
        // Don't configure strategy 
        // Attempt to call updatePricesAndCheckDrift without strategy configured
        vm.expectRevert("ENCRYPTED_STRATEGY_NOT_SET");
        freshVault.updatePricesAndCheckDriftHarness();
    }

    function testUpdatePricesAndCheckDrift_ReturnsNoRebalanceOnZeroTotal() public {
        // Create a fresh vault
        StealthfolioVaultHarnessFHE freshVault = new StealthfolioVaultHarnessFHE(manager, hook);

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
        freshVault.configureEncryptedStrategy(
            _encMinDriftBps, // minDriftBps: 1%
            _encBatchSizeBps, // batchSizeBps: 25%
            _encMinDriftCheckInterval // minDriftCheckInterval: 1 block
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


         InEuint16[] memory encryptedBpsInputs = new InEuint16[](3); 

        for (uint16 i = 0; i < bps.length; i++){
            InEuint16 memory _encBps = createInEuint16(bps[i] ,address(this));
            encryptedBpsInputs[i] = _encBps; 
        }


        freshVault.setEncryptedPortfolioTargets(assets, encryptedBpsInputs);

        // Set price feeds
        freshVault.setPriceFeed(currencyUSDC, address(usdcFeed));
        freshVault.setPriceFeed(currencyWBTC, address(wbtcFeed));
        freshVault.setPriceFeed(currencyWETH, address(wethFeed));

        // Simulate time to give time for decryption to happen
        vm.warp(block.timestamp + 5); 

        // Don't mint any balances - vault will have zero total value
        // Call updatePricesAndCheckDrift - should return early with shouldRebalance = false
        StealthfolioVaultFHE.DriftResult memory result = freshVault.updatePricesAndCheckDriftHarness();

        // Assert: shouldRebalance should be false when totalValue is 0
        assertFalse(result.shouldRebalance, "shouldRebalance should be false when totalValue is 0");
        assertEq(Currency.unwrap(result.targetAsset), address(0), "targetAsset should be zero address when totalValue is 0");
        assertEq(result.batches, 0, "batches should be 0 when totalValue is 0");
    }

    function testUpdatePricesAndCheckDrift_BelowDriftThreshold_NoRebalance() public {
        // Create a fresh vault
        StealthfolioVaultHarnessFHE freshVault = new StealthfolioVaultHarnessFHE(manager, hook);
        
        // Configure strategy with a high minDriftBps threshold (5% = 500 bps)
        // This ensures small drifts won't trigger rebalancing
        // Configure encrypted strategy for the vault 
        uint32 minDriftBps = 500;        // 5% (high threshold)
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
        freshVault.configureEncryptedStrategy(
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


        freshVault.setEncryptedPortfolioTargets(assets, encryptedBpsInputs);

        // Set price feeds
        freshVault.setPriceFeed(currencyUSDC, address(usdcFeed));
        freshVault.setPriceFeed(currencyWBTC, address(wbtcFeed));
        freshVault.setPriceFeed(currencyWETH, address(wethFeed));

        // Move time forward to perform decryption
        vm.warp(block.timestamp + 3); 

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
        StealthfolioVaultFHE.DriftResult memory result = freshVault.updatePricesAndCheckDriftHarness();

        // Assert: shouldRebalance should be false when drift is below minDriftBps threshold
        assertFalse(result.shouldRebalance, "shouldRebalance should be false when drift is below threshold");
        
        // Verify that lastDriftBps was set (even if below threshold)
        (uint16 lastDriftBps,,) = freshVault.strategyState();
        assertLt(lastDriftBps, 500, "lastDriftBps should be less than minDriftBps (500)");
        
        // The targetAsset may be set even if shouldRebalance is false
        // This is expected behavior per the implementation (line 339)
    }

    function test_updatePricesAndCheckDrift_returnsResult() public {
        StealthfolioVaultFHE.DriftResult memory result =
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
            (euint32 encryptedMinDriftBps, euint32 encryptedBatchSizeBps,  euint32 encryptedMinDriftCheckInterval, bool enabled) = vault.encryptedStrategyConfig(); 
            assertEq(
                Currency.unwrap(targetAsset),
                Currency.unwrap(result.targetAsset),
                "state targetAsset should match result"
            );


            (uint32 minDriftBps, bool minDriftBpsIsDecrypt) = FHE.getDecryptResultSafe(encryptedMinDriftBps);
            
            assertTrue(minDriftBpsIsDecrypt, "Not finished decryption"); 

            assertEq( uint32(lastDriftBps) >= minDriftBps, true, "drift bps should exceed threshold when rebalancing");
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

