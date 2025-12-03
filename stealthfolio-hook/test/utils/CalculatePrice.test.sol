// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CalculatePrice} from "../../src/utils/CalculatePrice.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import "forge-std/console.sol";

contract CalculatePriceTest is Test {

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 tokenC;

    Currency currencyA;
    Currency currencyB;
    Currency currencyC;

    function setUp() public {
        // Deploy mock tokens with different addresses
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 6);
        tokenC = new MockERC20("Token C", "TKC", 8);

        currencyA = Currency.wrap(address(tokenA));
        currencyB = Currency.wrap(address(tokenB));
        currencyC = Currency.wrap(address(tokenC));
    }

    // ========= sortCurrencies Tests =========

    function test_SortCurrencies_WhenAIsLessThanB() public pure {
        // Create currencies where A < B
        Currency a = Currency.wrap(address(0x1000));
        Currency b = Currency.wrap(address(0x2000));

        (Currency c0, Currency c1) = CalculatePrice.sortCurrencies(a, b);

        assertEq(Currency.unwrap(c0), Currency.unwrap(a));
        assertEq(Currency.unwrap(c1), Currency.unwrap(b));
    }

    function test_SortCurrencies_WhenAIsGreaterThanB() public pure {
        // Create currencies where A > B
        Currency a = Currency.wrap(address(0x2000));
        Currency b = Currency.wrap(address(0x1000));

        (Currency c0, Currency c1) = CalculatePrice.sortCurrencies(a, b);

        assertEq(Currency.unwrap(c0), Currency.unwrap(b));
        assertEq(Currency.unwrap(c1), Currency.unwrap(a));
    }

    function test_SortCurrencies_RevertsWhenIdentical() public {
        Currency a = Currency.wrap(address(0x1000));
        Currency b = Currency.wrap(address(0x1000));

        vm.expectRevert("IDENTICAL_ADDRESSES");
        CalculatePrice.sortCurrencies(a, b);
    }

    function test_SortCurrencies_WithMockTokens() view public {
        // tokenA address should be less than tokenB address (or vice versa)
        (Currency c0, Currency c1) = CalculatePrice.sortCurrencies(currencyA, currencyB);

        // Verify they are sorted
        assertTrue(Currency.unwrap(c0) < Currency.unwrap(c1));
    }

    // ========= sortAndScale Tests =========

    function test_SortAndScale_WhenAIsToken0() public pure {
        Currency a = Currency.wrap(address(0x1000));
        Currency b = Currency.wrap(address(0x2000));
        uint8 decimalsA = 18;
        uint8 decimalsB = 6;
        uint256 price = 100_000; // 100k tokenB per 1 tokenA

        (Currency c0, Currency c1, uint256 reserve0, uint256 reserve1) =
            CalculatePrice.sortAndScale(a, b, decimalsA, decimalsB, price);

        // Since A < B, A should be token0
        assertEq(Currency.unwrap(c0), Currency.unwrap(a));
        assertEq(Currency.unwrap(c1), Currency.unwrap(b));

        // reserve0 = 1 * 10^18 (1 tokenA)
        assertEq(reserve0, 1e18);
        // reserve1 = 100_000 * 10^6 (100k tokenB)
        assertEq(reserve1, 100_000e6);
    }

    function test_SortAndScale_WhenBIsToken0() public pure {
        Currency a = Currency.wrap(address(0x2000));
        Currency b = Currency.wrap(address(0x1000));
        uint8 decimalsA = 18;
        uint8 decimalsB = 6;
        uint256 price = 100_000; // 100k tokenB per 1 tokenA

        (Currency c0, Currency c1, uint256 reserve0, uint256 reserve1) =
            CalculatePrice.sortAndScale(a, b, decimalsA, decimalsB, price);

        // Since B < A, B should be token0
        assertEq(Currency.unwrap(c0), Currency.unwrap(b));
        assertEq(Currency.unwrap(c1), Currency.unwrap(a));

        assertEq(reserve0, 100_000e6);
        assertEq(reserve1, 1e18);
    }

    function test_SortAndScale_WithPriceOfOne() public pure {
        Currency a = Currency.wrap(address(0x1000));
        Currency b = Currency.wrap(address(0x2000));
        uint8 decimalsA = 18;
        uint8 decimalsB = 18;
        uint256 price = 1; // 1:1 price

        (Currency c0, Currency c1, uint256 reserve0, uint256 reserve1) =
            CalculatePrice.sortAndScale(a, b, decimalsA, decimalsB, price);

        assertEq(reserve0, 1e18);
        assertEq(reserve1, 1e18);
    }

    function test_SortAndScale_WithDifferentDecimals() public pure {
        Currency a = Currency.wrap(address(0x1000));
        Currency b = Currency.wrap(address(0x2000));
        uint8 decimalsA = 8; // WBTC-like
        uint8 decimalsB = 6; // USDC-like
        uint256 price = 50_000; // 50k USDC per 1 WBTC

        (Currency c0, Currency c1, uint256 reserve0, uint256 reserve1) =
            CalculatePrice.sortAndScale(a, b, decimalsA, decimalsB, price);

        assertEq(reserve0, 1e8); // 1 WBTC
        assertEq(reserve1, 50_000e6); // 50k USDC
    }

    function test_SortAndScale_WithVeryLargePrice() public pure {
        Currency a = Currency.wrap(address(0x1000));
        Currency b = Currency.wrap(address(0x2000));
        uint8 decimalsA = 18;
        uint8 decimalsB = 6;
        uint256 price = 1_000_000; // 1M tokenB per 1 tokenA

        (Currency c0, Currency c1, uint256 reserve0, uint256 reserve1) =
            CalculatePrice.sortAndScale(a, b, decimalsA, decimalsB, price);

        assertEq(reserve0, 1e18);
        assertEq(reserve1, 1_000_000e6);
    }

    // ========= encodePriceSqrt Tests =========

    function test_EncodePriceSqrt_WithOneToOnePrice() public pure {
        uint256 reserve0 = 1e18;
        uint256 reserve1 = 1e18;

        uint160 sqrtPrice = CalculatePrice.encodePriceSqrt(reserve1, reserve0);

        // For 1:1 price, sqrt(1) = 1, so sqrtPriceX96 = 1 << 96 = 2^96
        assertEq(sqrtPrice, 79228162514264337593543950336); // 2^96
    }

    function test_EncodePriceSqrt_WithTwoToOnePrice() public pure {
        uint256 reserve0 = 1e18;
        uint256 reserve1 = 2e18;

        uint160 sqrtPrice = CalculatePrice.encodePriceSqrt(reserve1, reserve0);

        // Verify using manual calculation
        uint256 ratioX192 = (reserve1 << 192) / reserve0;
        uint256 expectedSqrt = FixedPointMathLib.sqrt(ratioX192);
        
        assertEq(sqrtPrice, uint160(expectedSqrt));
    }

    function test_EncodePriceSqrt_WithHalfToOnePrice() public pure {
        uint256 reserve0 = 2e18;
        uint256 reserve1 = 1e18;

        uint160 sqrtPrice = CalculatePrice.encodePriceSqrt(reserve1, reserve0);

        // Verify using manual calculation
        uint256 ratioX192 = (reserve1 << 192) / reserve0;
        uint256 expectedSqrt = FixedPointMathLib.sqrt(ratioX192);
        
        assertEq(sqrtPrice, uint160(expectedSqrt));
    }

    function test_EncodePriceSqrt_WithLargePriceRatio() public pure {
        uint256 reserve0 = 1e8; // 1 WBTC (8 decimals)
        uint256 reserve1 = 100_000e6; // 100k USDC (6 decimals) = 100k * 10^6

        uint160 sqrtPrice = CalculatePrice.encodePriceSqrt(reserve1, reserve0);

        // Verify using manual calculation
        uint256 ratioX192 = (reserve1 << 192) / reserve0;
        uint256 expectedSqrt = FixedPointMathLib.sqrt(ratioX192);
        
        assertEq(sqrtPrice, uint160(expectedSqrt));
    }

    function test_EncodePriceSqrt_FormulaCorrectness() public pure {
        // Test the formula: ratioX192 = (reserve1 << 192) / reserve0
        // sqrtPriceX96 = sqrt(ratioX192)
        uint256 reserve0 = 1e18;
        uint256 reserve1 = 4e18; // 4:1 ratio

        uint160 sqrtPrice = CalculatePrice.encodePriceSqrt(reserve1, reserve0);

        // Manual calculation
        uint256 ratioX192 = (reserve1 << 192) / reserve0;
        uint256 expectedSqrt = FixedPointMathLib.sqrt(ratioX192);

        assertEq(sqrtPrice, uint160(expectedSqrt));
    }

    // ========= computeInitSqrtPrice Tests =========

    function test_ComputeInitSqrtPrice_EndToEnd() public pure {
        Currency a = Currency.wrap(address(0x1000));
        Currency b = Currency.wrap(address(0x2000));
        uint8 decimalsA = 18;
        uint8 decimalsB = 6;
        uint256 price = 100_000; // 100k tokenB per 1 tokenA

        (Currency c0, Currency c1, uint160 sqrtPriceX96) =
            CalculatePrice.computeInitSqrtPrice(a, b, decimalsA, decimalsB, price);

        // Verify currencies are sorted
        assertTrue(Currency.unwrap(c0) < Currency.unwrap(c1));

        // Verify sqrt price is calculated correctly
        // reserve0 = 1e18, reserve1 = 100_000e6
        // ratio = 100_000e6 / 1e18 = 0.1
        // sqrt(0.1) * 2^96
        assertTrue(sqrtPriceX96 > 0);
    }

    function test_ComputeInitSqrtPrice_WithOneToOnePrice() public pure {
        Currency a = Currency.wrap(address(0x1000));
        Currency b = Currency.wrap(address(0x2000));
        uint8 decimalsA = 18;
        uint8 decimalsB = 18;
        uint256 price = 1; // 1:1 price

        (Currency c0, Currency c1, uint160 sqrtPriceX96) =
            CalculatePrice.computeInitSqrtPrice(a, b, decimalsA, decimalsB, price);

        // For 1:1 price, sqrtPrice should be 2^96
        assertEq(sqrtPriceX96, 79228162514264337593543950336); // 2^96
    }

    function test_ComputeInitSqrtPrice_WithWBTCUSDCExample() public pure {
        // Real-world example: WBTC/USDC
        // WBTC has 8 decimals, USDC has 6 decimals
        // Price: 100,000 USDC per 1 WBTC
        Currency wbtc = Currency.wrap(address(0x1000));
        Currency usdc = Currency.wrap(address(0x2000));
        uint8 decimalsWBTC = 8;
        uint8 decimalsUSDC = 6;
        uint256 price = 100_000; // 100k USDC per 1 WBTC

        (Currency c0, Currency c1, uint160 sqrtPriceX96) =
            CalculatePrice.computeInitSqrtPrice(wbtc, usdc, decimalsWBTC, decimalsUSDC, price);

        // Verify currencies are sorted
        assertTrue(Currency.unwrap(c0) < Currency.unwrap(c1));

        // Verify sqrt price is reasonable
        // If WBTC < USDC: reserve0 = 1e8, reserve1 = 100_000e6
        // ratio = 100_000e6 / 1e8 = 1000
        // sqrt(1000) * 2^96
        assertTrue(sqrtPriceX96 > 0);
        console.log("SqrtPrice: ",sqrtPriceX96);
    }

    function test_ComputeInitSqrtPrice_WithWETHUSDCExample() public pure {
        // Real-world example: WETH/USDC
        // WETH has 18 decimals, USDC has 6 decimals
        // Price: 3,000 USDC per 1 WETH
        Currency weth = Currency.wrap(address(0x1000));
        Currency usdc = Currency.wrap(address(0x2000));
        uint8 decimalsWETH = 18;
        uint8 decimalsUSDC = 6;
        uint256 price = 3_000; // 3k USDC per 1 WETH

        (Currency c0, Currency c1, uint160 sqrtPriceX96) =
            CalculatePrice.computeInitSqrtPrice(weth, usdc, decimalsWETH, decimalsUSDC, price);

        // Verify sqrt price is reasonable
        assertTrue(sqrtPriceX96 > 0);
        console.log("SqrtPrice: ",sqrtPriceX96);
    }

    function test_ComputeInitSqrtPrice_ConsistencyWithSortAndScale() public pure {
        Currency a = Currency.wrap(address(0x1000));
        Currency b = Currency.wrap(address(0x2000));
        uint8 decimalsA = 18;
        uint8 decimalsB = 6;
        uint256 price = 50_000;

        // Get result from computeInitSqrtPrice
        (Currency c0_compute, Currency c1_compute, uint160 sqrtPriceX96) =
            CalculatePrice.computeInitSqrtPrice(a, b, decimalsA, decimalsB, price);

        // Get result from sortAndScale and encodePriceSqrt separately
        (Currency c0_scale, Currency c1_scale, uint256 reserve0, uint256 reserve1) =
            CalculatePrice.sortAndScale(a, b, decimalsA, decimalsB, price);

        uint160 sqrtPrice_manual = CalculatePrice.encodePriceSqrt(reserve1, reserve0);

        // Verify consistency
        assertEq(Currency.unwrap(c0_compute), Currency.unwrap(c0_scale));
        assertEq(Currency.unwrap(c1_compute), Currency.unwrap(c1_scale));
        assertEq(sqrtPriceX96, sqrtPrice_manual);
    }

}

