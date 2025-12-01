// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// OpenZeppelin
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Uniswap v4 imports
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey, PoolIdLibrary} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract StealthfolioHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;

    constructor(IPoolManager _manager) BaseHook(_manager) Ownable(msg.sender) {}

    // ========= Permissions =========

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ========= Strategy Config & State (single vault) =========

    struct StrategyConfig {
        uint16 minDriftBps;
        uint16 batchSizeBps;
        uint32 rebalanceCooldown;
        uint256 maxExternalSwapAmount;
        address vault;
        address executor;
    }

    struct StrategyState {
        uint16 lastDriftBps;
        bool   rebalancePending;
        uint32 nextBatchBlock;
        uint32 batchesRemaining;
        uint256 lastRebalanceBlock;

        Currency targetAsset;
        bool     lastDeltaPositive;
    }

    StrategyConfig public strategyConfig;
    StrategyState  public strategyState;

    // ========= Portfolio =========

    Currency public baseAsset;               // e.g. USDC / USDT 

    Currency[] public portfolioAssets;       // e.g. [WBTC, WETH, USDC]

    mapping(Currency => uint16) public targetAllocBps; // Currency -> allocation BPS
    mapping(Currency => int256) public assetPositions; // Currency -> current balance positions
    mapping(Currency => uint256) public lastPriceInBase; // 1e18 scaled

    // ========= Pools =========

    mapping(PoolId => bool) public isStrategyPool;
    mapping(PoolId => PoolKey) public poolKeys;
    mapping(Currency => PoolId) public rebalancePool; // asset => poolId(asset/base)

    // ========= Events =========

    event StrategyConfigured(
        address indexed vault,
        address indexed executor,
        Currency baseAsset
    );

    event StrategyPoolRegistered(
        PoolId indexed poolId,
        Currency currency0,
        Currency currency1
    );

    event RebalancePoolSet(
        Currency indexed asset,
        PoolId indexed poolId
    );

    event RebalanceBatchPlanned(
        Currency indexed asset,
        PoolId indexed poolId,
        bool zeroForOne,
        uint256 amountSpecified
    );

    // ========= Admin: strategy & portfolio =========

    function configureStrategy(
        address _vault,
        address _executor,
        Currency _baseAsset,
        uint16 _minDriftBps,
        uint16 _batchSizeBps,
        uint32 _rebalanceCooldown,
        uint256 _maxExternalSwapAmount
    ) external onlyOwner {
        require(_vault != address(0), "Vault is address zero");
        require(_executor != address(0), "Executor is address zero");
        require(
            Currency.unwrap(baseAsset) == address(0) || baseAsset == _baseAsset,
            "Base address is zero / already set"
        );
        require(_batchSizeBps > 0 && _batchSizeBps <= 10_000, "Invalid Batch Size ");

        baseAsset = _baseAsset;

        strategyConfig = StrategyConfig({
            minDriftBps: _minDriftBps,
            batchSizeBps: _batchSizeBps,
            rebalanceCooldown: _rebalanceCooldown,
            maxExternalSwapAmount: _maxExternalSwapAmount,
            vault: _vault,
            executor: _executor
        });

        strategyState.lastDriftBps = 0;
        strategyState.rebalancePending = false;
        strategyState.batchesRemaining = 0;
        strategyState.lastRebalanceBlock = block.number;
        strategyState.targetAsset = Currency.wrap(address(0)); // No target asset during init
        strategyState.lastDeltaPositive = false;

        emit StrategyConfigured(_vault, _executor, _baseAsset);
    }

    function setPortfolioTargets(
        Currency[] calldata assets,
        uint16[] calldata bps
    ) external onlyOwner {
        require(assets.length == bps.length, "Asset and bps length mismatched");
        require(Currency.unwrap(baseAsset) != address(0), "Base is address zero");

        delete portfolioAssets;

        uint16 total;
        bool baseSeen = false;

        for (uint256 i = 0; i < assets.length; i++) {
            require(Currency.unwrap(assets[i]) != address(0), "Address Zero Asset");
            require(bps[i] > 0, "Zero BPS");

            portfolioAssets.push(assets[i]);
            targetAllocBps[assets[i]] = bps[i];
            total += bps[i];

            if (assets[i] == baseAsset) {
                baseSeen = true;
            } 
        }

        require(total == 10_000, "Total BPS is not 100%");
        require(baseSeen, "Base Asset not in portfolio");
    }

    // ========= Admin: pools =========

    function registerStrategyPool(PoolKey calldata key) external onlyOwner {
        PoolId poolId = key.toId();
        isStrategyPool[poolId] = true;
        poolKeys[poolId] = key;
        emit StrategyPoolRegistered(poolId, key.currency0, key.currency1);
    }

    function setRebalancePool(Currency asset, PoolKey calldata key) external onlyOwner {
        require(!(asset ==  baseAsset), "ASSET_IS_BASE");
        PoolId poolId = key.toId();
        require(isStrategyPool[poolId], "POOL_NOT_STRATEGY");
        require(
            key.currency0 == asset || key.currency1 == asset,
            "POOL_MISSING_ASSET"
        );
        require(
            key.currency0 == baseAsset || key.currency1 == baseAsset,
            "POOL_MISSING_BASE"
        );

        rebalancePool[asset] = poolId;
        emit RebalancePoolSet(asset, poolId);
    }

    // ========= Hook: afterSwap (track vault positions) =========

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();

        if (!isStrategyPool[poolId]) {
            return (BaseHook.afterSwap.selector, 0);
        }

        if (sender != strategyConfig.vault) {
            return (BaseHook.afterSwap.selector, 0);
        }

        Currency c0 = key.currency0;
        Currency c1 = key.currency1;

        int256 d0 = int256(delta.amount0());
        int256 d1 = int256(delta.amount1());

        // // vault position = -pool delta (negative of pool delta)
        assetPositions[c0] -= d0;
        assetPositions[c1] -= d1;

        return (BaseHook.afterSwap.selector, 0);
    }

    // ========= Drift detection =========

    function checkAndMarkRebalance(uint256[] calldata pricesInBase) external {
        StrategyConfig memory cfg = strategyConfig;
        StrategyState storage st = strategyState;

        require(msg.sender == cfg.executor, "NOT_EXECUTOR");
        require(cfg.vault != address(0), "NO_STRATEGY");
        require(pricesInBase.length == portfolioAssets.length, "BAD_PRICE_LEN");

        if (block.number < st.lastRebalanceBlock + cfg.rebalanceCooldown) {
            return;
        }

        uint256 totalValue;
        uint256[] memory values = new uint256[](portfolioAssets.length);

        // Compute current portfolio value & store prices
        for (uint256 i = 0; i < portfolioAssets.length; i++) {
            Currency asset = portfolioAssets[i];
            uint256 price = pricesInBase[i];
            lastPriceInBase[asset] = price;

            int256 pos = assetPositions[asset];
            require(pos >= 0, "NEG_POSITION");

            uint256 v = uint256(pos) * price / 1e18;
            values[i] = v;
            totalValue += v;
        }

        if (totalValue == 0) {
            return;
        }

        Currency maxAsset = Currency.wrap(address(0));
        uint256 maxAbsDev = 0;
        bool deltaPositive = false;

        // find non-base asset with max deviation
        for (uint256 i = 0; i < portfolioAssets.length; i++) {
            Currency asset = portfolioAssets[i];
            if (asset == baseAsset) continue;

            uint16 tBps = targetAllocBps[asset];
            if (tBps == 0) continue;

            uint256 targetValue = totalValue * tBps / 10_000;
            int256 dev = int256(targetValue) - int256(values[i]);
            uint256 absDev = _abs(dev);

            if (absDev > maxAbsDev) {
                maxAbsDev = absDev;
                maxAsset = asset;
                deltaPositive = (dev > 0);
            }
        }

        if (maxAbsDev == 0 || Currency.unwrap(maxAsset) == address(0)) {
            return;
        }

        uint16 driftBps = uint16(maxAbsDev * 10_000 / totalValue);
        st.lastDriftBps = driftBps;

        if (driftBps < cfg.minDriftBps) {
            return;
        }

        PoolId poolId = rebalancePool[maxAsset];
        require(PoolId.unwrap(poolId) != bytes32(0), "NO_REBAL_POOL");

        uint256 perBatchValue = maxAbsDev * cfg.batchSizeBps / 10_000;
        if (perBatchValue == 0) perBatchValue = maxAbsDev;

        uint32 batches = uint32((maxAbsDev + perBatchValue - 1) / perBatchValue);
        if (batches == 0) batches = 1;

        st.rebalancePending  = true;
        st.batchesRemaining  = batches;
        st.nextBatchBlock    = uint32(block.number);
        st.targetAsset       = maxAsset;
        st.lastDeltaPositive = deltaPositive;
    }

    // ========= Batch computation & getters =========

    function _computeBatchParams()
        internal
        view
        returns (PoolKey memory poolKey, bool zeroForOne, uint256 amountSpecified)
    {
        StrategyConfig memory cfg = strategyConfig;
        StrategyState memory st = strategyState;

        require(st.rebalancePending, "NO_REBALANCE");
        require(st.batchesRemaining > 0, "NO_BATCHES");

        Currency asset = st.targetAsset;
        require(Currency.unwrap(asset) != address(0), "NO_TARGET_ASSET");

        PoolId poolId = rebalancePool[asset];
        require(PoolId.unwrap(poolId) != bytes32(0), "NO_POOL");

        poolKey = poolKeys[poolId];

        uint256 totalValue;
        uint256 assetValue;
        uint256 priceAsset = lastPriceInBase[asset];

        for (uint256 i = 0; i < portfolioAssets.length; i++) {
            Currency a = portfolioAssets[i];
            uint256 price = lastPriceInBase[a];
            if (price == 0) continue;

            int256 pos = assetPositions[a];
            require(pos >= 0, "NEG_POSITION");

            uint256 v = uint256(pos) * price / 1e18;
            totalValue += v;
            if (a == asset) {
                assetValue = v;
            }
        }

        require(totalValue > 0, "ZERO_TOTAL_VALUE");

        uint16 tBps = targetAllocBps[asset];
        uint256 targetValue = totalValue * tBps / 10_000;
        int256 dev = int256(targetValue) - int256(assetValue);
        uint256 absDev = _abs(dev);

        if (absDev == 0) {
            amountSpecified = 0;
            zeroForOne = false;
            return (poolKey, zeroForOne, amountSpecified);
        }

        uint256 batchValue = absDev * cfg.batchSizeBps / 10_000;
        if (batchValue == 0 || batchValue > absDev) {
            batchValue = absDev;
        }

        amountSpecified = (batchValue * 1e18) / priceAsset;

        bool assetIsToken0 = (asset == poolKey.currency0);

        if (assetIsToken0) {
            if (dev > 0) {
                zeroForOne = false; // buy asset with base
            } else {
                zeroForOne = true;  // sell asset for base
            }
        } else {
            if (dev > 0) {
                zeroForOne = true;  // buy asset with base
            } else {
                zeroForOne = false; // sell asset for base
            }
        }

        return (poolKey, zeroForOne, amountSpecified);
    }

    function getNextBatch()
        external
        view
        returns (
            bool canExecute,
            PoolKey memory poolKey,
            bool zeroForOne,
            uint256 amountSpecified
        )
    {
        StrategyState memory st = strategyState;

        if (!st.rebalancePending || st.batchesRemaining == 0) {
            return (false, poolKey, false, 0);
        }
        if (block.number < st.nextBatchBlock) {
            return (false, poolKey, false, 0);
        }

        (poolKey, zeroForOne, amountSpecified) = _computeBatchParams();
        canExecute = (amountSpecified > 0);
    }

    function markBatchExecuted() external {
        StrategyConfig memory cfg = strategyConfig;
        StrategyState storage st = strategyState;

        require(msg.sender == cfg.executor, "NOT_EXECUTOR");
        require(st.rebalancePending, "NO_REBALANCE");
        require(st.batchesRemaining > 0, "NO_BATCHES");
        require(block.number >= st.nextBatchBlock, "TOO_EARLY");

        (PoolKey memory poolKey, bool zeroForOne, uint256 amountSpecified) =
            _computeBatchParams();

        PoolId poolId = poolKey.toId();

        emit RebalanceBatchPlanned(
            st.targetAsset,
            poolId,
            zeroForOne,
            amountSpecified
        );

        if (st.batchesRemaining > 0) {
            st.batchesRemaining -= 1;
        }

        if (st.batchesRemaining == 0) {
            st.rebalancePending = false;
            st.lastRebalanceBlock = block.number;
        } else {
            st.nextBatchBlock = uint32(block.number + 1);
        }
    }

    // ========= Hook: beforeSwap (drift guard) =========

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();

        if (!isStrategyPool[poolId]) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        StrategyConfig memory cfg = strategyConfig;
        StrategyState memory st = strategyState;

        if (!st.rebalancePending) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        if (sender == cfg.vault) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 absAmount = params.amountSpecified > 0
            ? uint256(params.amountSpecified)
            : uint256(-params.amountSpecified);

        require(
            absAmount <= cfg.maxExternalSwapAmount,
            "REBAL_PROTECTED"
        );

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // Sync Positions
    function syncPositionsFromVault() external onlyOwner {
        StrategyConfig memory cfg = strategyConfig;
        require(cfg.vault != address(0), "NO_VAULT");

        for (uint256 i = 0; i < portfolioAssets.length; i++) {
            Currency asset = portfolioAssets[i];
            address token = Currency.unwrap(asset);

            // base asset can also be an ERC20; if it's native you’d handle differently
            uint256 bal = IERC20(token).balanceOf(cfg.vault);
            assetPositions[asset] = int256(bal);
        }
}


    // ========= Helper =========

    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }
}
