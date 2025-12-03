// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import {Currency} from "v4-core/types/Currency.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

library CalculatePrice {

    function sortCurrencies(Currency a, Currency b)
    public
    pure
    returns (Currency c0, Currency c1)
    {
        require(!(a == b), "IDENTICAL_ADDRESSES");
        (c0, c1) = Currency.unwrap(a) < Currency.unwrap(b)
            ? (a, b)
            : (b, a);
    }

    function sortAndScale(
        Currency a,
        Currency b,
        uint8 decimalsA,
        uint8 decimalsB,
        uint256 priceTokenBperTokenA   // B per 1 A, e.g. 100k USDC per 1 WBTC
    )
        internal
        pure
        returns (
            Currency c0,
            Currency c1,
            uint256 reserve0,
            uint256 reserve1
        )
    {
        (c0, c1) = sortCurrencies(a, b);

        // Step 1: assume token0 = A, token1 = B
        uint256 reserve0_A0 = 10 ** decimalsA;                       // 1 A
        uint256 reserve1_A0 = priceTokenBperTokenA * (10 ** decimalsB); // price * 1 B unit

        // Step 2: if sorting kept A as token0, use as-is. Otherwise swap.
        if (c0 == a) {
            // token0 = A, token1 = B
            reserve0 = reserve0_A0;
            reserve1 = reserve1_A0;
        } else {
            // token0 = B, token1 = A
            reserve0 = reserve1_A0; // B side becomes token0
            reserve1 = reserve0_A0; // A side becomes token1
        }
    }

    function computeInitSqrtPrice(
    Currency a,
    Currency b,
    uint8 decimalsA,
    uint8 decimalsB,
    uint256 priceTokenBperTokenA   // e.g. 100_000 USDC per 1 WBTC
)
    public
    pure
    returns (
        Currency c0,
        Currency c1,
        uint160 sqrtPriceX96
    )
{
    (Currency _c0, Currency _c1, uint256 reserve0, uint256 reserve1) =
        sortAndScale(a, b, decimalsA, decimalsB, priceTokenBperTokenA);

    c0 = _c0;
    c1 = _c1;

    sqrtPriceX96 = encodePriceSqrt(reserve1, reserve0);
}




    function encodePriceSqrt(uint256 reserve1, uint256 reserve0)
    public
    pure
    returns (uint160)
    {
        uint256 ratioX192 = (reserve1 << 192) / reserve0;
        uint256 sqrtX96 = FixedPointMathLib.sqrt(ratioX192);
        return uint160(sqrtX96);
    }

}