// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {MockV3Aggregator} from "@chainlink/local/src/data-feeds/MockV3Aggregator.sol";
import {StealthfolioHook} from "./hooks/StealthfolioHook.sol";

contract StealthfolioVault is Ownable {
    IPoolManager public immutable manager;
    StealthfolioHook public immutable hook;

    using CurrencyLibrary for Currency;

    // ========= Strategy config/state (moved from hook) =========

    struct StrategyConfig {
        uint16 minDriftBps; // minimum drift in bps before rebalancing
        uint16 batchSizeBps; // per-batch fraction of deviation (bps)
        uint32 minDriftCheckInterval; // min blocks between drift checks
    }

    struct StrategyState {
        uint16 lastDriftBps;
        uint32 lastDriftCheckBlock; // last time drift was computed
        Currency targetAsset;
        bool lastDeltaPositive;
    }

    StrategyConfig public strategyConfig;
    StrategyState public strategyState;

    // Portfolio / oracle config owned by the vault
    Currency public baseAsset; // e.g. USDC / USDT
    Currency[] public portfolioAssets; // e.g. [WBTC, WETH, USDC]
    mapping(Currency => uint16) public targetAllocBps; // Currency -> allocation BPS
    mapping(Currency => uint256) public lastPriceInBase; // 1e18 scaled
    mapping(Currency => MockV3Aggregator) public priceFeeds;

    constructor(
        IPoolManager _manager,
        StealthfolioHook _hook
    ) Ownable(msg.sender){
        manager = _manager;
        hook = _hook;
    }

    // ======================
    // Deposit / Withdraw
    // ======================

    function deposit(IERC20 token, uint256 amount) external onlyOwner {
        token.transferFrom(msg.sender, address(this), amount);
    }

    function withdraw(IERC20 token, uint256 amount) external onlyOwner {
        token.transfer(msg.sender, amount);
    }

    // ======================
    // Portfolio Insight (Optional)
    // ======================

    function getVaultBalances(IERC20[] calldata tokens)
        external
        view
        returns (uint256[] memory balances)
    {
        balances = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            balances[i] = tokens[i].balanceOf(address(this));
        }
    }

    // ======================
    // Admin: strategy & portfolio
    // ======================

    function configureStrategy(
        uint16 _minDriftBps,
        uint16 _batchSizeBps,
        uint32 _minDriftCheckInterval
    ) external onlyOwner {
        require(_batchSizeBps > 0 && _batchSizeBps <= 10_000, "INVALID_BATCH_BPS");

        baseAsset = hook.baseAsset();

        strategyConfig = StrategyConfig({
            minDriftBps: _minDriftBps,
            batchSizeBps: _batchSizeBps,
            minDriftCheckInterval: _minDriftCheckInterval
        });

        strategyState = StrategyState({
            lastDriftBps: 0,
            lastDriftCheckBlock: 0,
            targetAsset: Currency.wrap(address(0)),
            lastDeltaPositive: false
        });
    }

    function setPortfolioTargets(
        Currency[] calldata assets,
        uint16[] calldata bps
    ) external onlyOwner {
        require(assets.length == bps.length, "ASSETS_BPS_LEN");
        require(Currency.unwrap(baseAsset) != address(0), "BASE_ZERO");

        delete portfolioAssets;

        uint16 total;
        bool baseSeen = false;

        for (uint256 i = 0; i < assets.length; i++) {
            require(Currency.unwrap(assets[i]) != address(0), "ASSET_ZERO");
            require(bps[i] > 0, "BPS_ZERO");

            portfolioAssets.push(assets[i]);
            targetAllocBps[assets[i]] = bps[i];
            total += bps[i];

            if (assets[i] == baseAsset) {
                baseSeen = true;
            }
        }

        require(total == 10_000, "TOTAL_BPS_NEQ_100");
        require(baseSeen, "BASE_NOT_IN_PORTFOLIO");
    }

    function setPriceFeed(Currency asset, address feed) external onlyOwner {
        require(feed != address(0), "FEED_ZERO");
        priceFeeds[asset] = MockV3Aggregator(feed);
    }

    // ======================
    // Internal: drift detection & batch computation
    // ======================

    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    /**
     * @notice Updates prices from oracles and decides if a rebalance should start.
     * @dev Returns (shouldRebalance, targetAsset, batches).
     */
    function _updatePricesAndCheckDrift()
        internal
        returns (bool, Currency, uint32)
    {
        StrategyConfig memory cfg = strategyConfig;
        StrategyState storage st = strategyState;

        require(Currency.unwrap(baseAsset) != address(0), "NO_BASE");

        // Throttle drift checks to avoid spam
        if (st.lastDriftCheckBlock != 0) {
            require(
                block.number >=
                    st.lastDriftCheckBlock + cfg.minDriftCheckInterval,
                "DRIFT_CHECK_TOO_SOON"
            );
        }
        st.lastDriftCheckBlock = uint32(block.number);

        uint256 totalValue;
        uint256[] memory values = new uint256[](portfolioAssets.length);

        // Compute current portfolio value & store prices
        for (uint256 i = 0; i < portfolioAssets.length; i++) {
            Currency asset = portfolioAssets[i];
            MockV3Aggregator feed = priceFeeds[asset];
            require(address(feed) != address(0), "NO_PRICE_FEED");

            (, int256 latestPrice, , , ) = feed.latestRoundData();
            require(latestPrice > 0, "INVALID_PRICE");
            uint8 feedDecimals = feed.decimals();

            uint256 price = uint256(latestPrice);
            // normalize to 1e18
            if (feedDecimals < 18) {
                price *= 10 ** (18 - feedDecimals);
            } else if (feedDecimals > 18) {
                price /= 10 ** (feedDecimals - 18);
            }
            lastPriceInBase[asset] = price;

            address token = Currency.unwrap(asset);
            uint256 bal = IERC20(token).balanceOf(address(this));

            uint256 v = (bal * price) / 1e18;
            values[i] = v;
            totalValue += v;
        }

        if (totalValue == 0) {
            return (false, Currency.wrap(address(0)), 0);
        }

        Currency maxAsset = Currency.wrap(address(0));
        uint256 maxAbsDev = 0;
        bool deltaPositive = false;

        // Find non-base asset with max deviation from target
        for (uint256 i = 0; i < portfolioAssets.length; i++) {
            Currency asset = portfolioAssets[i];
            if (asset == baseAsset) {
                continue;
            }

            uint16 tBps = targetAllocBps[asset];
            if (tBps == 0) {
                continue;
            }

            uint256 targetValue = (totalValue * tBps) / 10_000;
            int256 dev = int256(targetValue) - int256(values[i]);
            uint256 absDev = _abs(dev);

            if (absDev > maxAbsDev) {
                maxAbsDev = absDev;
                maxAsset = asset;
                deltaPositive = (dev > 0);
            }
        }

        if (maxAbsDev == 0 || Currency.unwrap(maxAsset) == address(0)) {
            return (false, Currency.wrap(address(0)), 0);
        }

        uint16 driftBps = uint16((maxAbsDev * 10_000) / totalValue);
        st.lastDriftBps = driftBps;
        st.targetAsset = maxAsset;
        st.lastDeltaPositive = deltaPositive;

        if (driftBps < cfg.minDriftBps) {
            return (false, maxAsset, 0);
        }

        // Per-batch value in base terms
        uint256 perBatchValue = (maxAbsDev * cfg.batchSizeBps) / 10_000;
        if (perBatchValue == 0) {
            perBatchValue = maxAbsDev;
        }

        uint32 batches = uint32((maxAbsDev + perBatchValue - 1) / perBatchValue);
        if (batches == 0) {
            batches = 1;
        }

        return (true, maxAsset, batches);
    }

    /**
     * @notice Computes the next batch swap using cached prices.
     */
    function _computeBatchParams()
        internal
        view
        returns (PoolKey memory poolKey, bool zeroForOne, uint256 amountSpecified)
    {
        StrategyConfig memory cfg = strategyConfig;
        StrategyState memory st = strategyState;

        Currency asset = st.targetAsset;
        require(Currency.unwrap(asset) != address(0), "NO_TARGET_ASSET");

        // Pool selection is still configured on the hook
        poolKey = hook.getRebalancePoolKey(asset); 

        uint256 totalValue;
        uint256 assetValue;
        uint256 priceAsset = lastPriceInBase[asset];
        require(priceAsset > 0, "MISSING_PRICE");

        // recompute total portfolio value (using cached prices)
        for (uint256 i = 0; i < portfolioAssets.length; i++) {
            Currency a = portfolioAssets[i];
            uint256 price = lastPriceInBase[a];
            if (price == 0) continue;

            address token = Currency.unwrap(a);
            uint256 bal = IERC20(token).balanceOf(address(this));

            uint256 v = (bal * price) / 1e18;
            totalValue += v;
            if (a == asset) {
                assetValue = v;
            }
        }

        require(totalValue > 0, "ZERO_TOTAL_VALUE");

        uint16 tBps = targetAllocBps[asset];
        uint256 targetValue = (totalValue * tBps) / 10_000;
        int256 dev = int256(targetValue) - int256(assetValue);
        uint256 absDev = _abs(dev);

        if (absDev == 0) {
            amountSpecified = 0;
            zeroForOne = false;
            return (poolKey, zeroForOne, amountSpecified);
        }

        // per-batch value
        uint256 batchValue = (absDev * cfg.batchSizeBps) / 10_000;
        if (batchValue == 0 || batchValue > absDev) {
            batchValue = absDev;
        }

        // convert value in base terms into asset amount using last price
        amountSpecified = (batchValue * 1e18) / priceAsset;

        bool assetIsToken0 = (asset == poolKey.currency0);

        // dev > 0 => asset underweight => we need to BUY asset with base
        if (assetIsToken0) {
            if (dev > 0) {
                zeroForOne = false; // base -> asset (1 -> 0)
            } else {
                zeroForOne = true;  // asset -> base (0 -> 1)
            }
        } else {
            if (dev > 0) {
                zeroForOne = true;  // base -> asset
            } else {
                zeroForOne = false; // asset -> base
            }
        }

        return (poolKey, zeroForOne, amountSpecified);
    }

    // ======================
    // Rebalance: Main Step
    // ======================

    /**
     * @notice Performs ONE rebalance batch:
     *  1. Update prices and compute drift
     *  2. If needed, open rebalance window on hook
     *  3. Compute next batch swap from vault state
     *  4. Execute swap with PoolManager
     *  5. Notify hook of executed batch
     */
    function rebalanceStep() external onlyOwner {
        // 1. Mark drift and decide whether to start/continue a rebalance
        (bool shouldRebalance, Currency targetAsset, uint32 batches) =
            _updatePricesAndCheckDrift();

        // If a new drift above threshold appears and no rebalance is pending, open window on hook
        (bool pendingRebalance, , , , ) = hook.rebalanceState();
        if (shouldRebalance && !pendingRebalance) {
            hook.startRebalance(targetAsset, batches);
        }

        // If still no rebalance, nothing to do
        if (!pendingRebalance) {
            return;
        }

        // 2. Fetch batch params from vault strategy math
        (PoolKey memory key, bool zeroForOne, uint256 amountSpecified) =
            _computeBatchParams();

        if (amountSpecified == 0) {
            return;
        }

        // 3. Approve tokens if needed
        _approveIfNeeded(key, amountSpecified, zeroForOne);

        // 4. Execute swap through PoolManager
        _executeSwap(key, zeroForOne, amountSpecified);

        // 5. Notify hook with executed batch details
        hook.markBatchExecuted(key, zeroForOne, amountSpecified);
    }

    // ======================
    // Internal
    // ======================

    function _approveIfNeeded(
        PoolKey memory key,
        uint256 amount,
        bool zeroForOne
    ) internal {
        address tokenIn = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);

        IERC20(tokenIn).approve(address(manager), amount);
    }

    function _executeSwap(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountSpecified
    ) internal {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountSpecified),
            // Use the min/max sqrt price limits recommended by v4-core:
            // - for zeroForOne, set a lower bound just above MIN_SQRT_PRICE
            // - for oneForZero, set an upper bound just below MAX_SQRT_PRICE
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        manager.swap(key, params, bytes(""));
    }
}
