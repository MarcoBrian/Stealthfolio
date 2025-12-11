// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// OpenZeppelin
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol"; 

contract StealthfolioHook is BaseHook, Ownable, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;




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
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ========= Hook Config & State (single vault) =========

    struct HookConfig {
        uint32 rebalanceCooldown; // blocks between completed rebalances
        uint32 rebalanceMaxDuration; // max blocks a rebalance can stay "pending"
        address vault;
    }

    struct RebalanceState {
        bool rebalancePending;
        uint32 nextBatchBlock; // earliest block when next batch can execute
        uint32 batchesRemaining;
        uint256 lastRebalanceBlock; // last time a rebalance cycle fully completed
        Currency targetAsset;
    }

    HookConfig public hookConfig;
    RebalanceState public rebalanceState;

    // ========= Pools / Strategy Metadata =========

    Currency public baseAsset; // e.g. USDC / USDT

    mapping(PoolId => bool) public isStrategyPool;
    mapping(PoolId => PoolKey) public poolKeys;
    mapping(Currency => PoolId) public rebalancePool; // asset => poolId(asset/base)

    // ======== Hook Safeguards =============

    // Volatility band safeguards to prevent making trades on highly manipulated environments
    struct VolBand {
        uint160 centerSqrtPriceX96;  
        uint16 widthBps; // +/- band in basis points, e.x 500 = +/- 5% 
        bool enabled; 
    }

    mapping(PoolId => VolBand) internal volBands;

    // Max Trade guards to prevent big price changes and manipulation
    struct MaxTradeGuard {
        uint256 maxAmount;
        bool enabled; 
    }

    mapping(PoolId => MaxTradeGuard) public maxTradeGuards;

    // Toxic Flow safe guards 
    struct ToxicFlowConfig {
        bool enabled;

        uint32 windowBlocks;          // length of window, e.g. 20 blocks
        uint8  maxSameDirLargeTrades; // max # of large trades in same direction per window, e.g. 3
        uint256 minLargeTradeAmount;  // only count trades >= this size (raw token units)
    }

    struct ToxicFlowState {
        uint32 windowStartBlock;
        uint8 sameDirCount;
        bool lastZeroForOne;
    }

    mapping(PoolId => ToxicFlowConfig) public toxicConfigs;
    mapping(PoolId => ToxicFlowState) internal toxicStates;

    // ========= Events =========

    event VolBandUpdated(
        PoolId indexed poolId,
        uint160 centerSqrtPriceX96,
        uint16 widthBps,
        bool enabled
    );


    event MaxTradeGuardUpdated(
        PoolId indexed poolId,
        uint256 maxAmount,
        bool enabled
    );

     event ToxicFlowConfigUpdated(
        PoolId indexed poolId,
        bool enabled,
        uint32 windowBlocks,
        uint8 maxSameDirLargeTrades,
        uint256 minLargeTradeAmount
    );

    event HookConfigured(
        address indexed vault,
        Currency baseAsset,
        uint32 rebalanceCooldown,
        uint32 rebalanceMaxDuration
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

    // ========= Modifiers =========

    modifier onlyVault() {
        require(msg.sender == hookConfig.vault, "NOT_VAULT");
        _;
    }

    // ========= Admin: hook config =========

    // Set volatility band 
    function setVolBand(PoolKey  calldata key, uint160 centerSqrtPriceX96, uint16 widthBps) external onlyOwner {
        PoolId poolId = key.toId(); 
        require(isStrategyPool[poolId], "Pool not strategy"); 
        require(widthBps > 0, "Width zero"); 

        // if center is zero anchor to current sqrtPrice 
        if (centerSqrtPriceX96 == 0) {
                (uint160 currentSqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
            centerSqrtPriceX96 = currentSqrtPriceX96;
        } 
        
        volBands[poolId] = VolBand({
            centerSqrtPriceX96: centerSqrtPriceX96,
            widthBps: widthBps,
            enabled: true
        });

        emit VolBandUpdated(poolId, centerSqrtPriceX96, widthBps, true);
    }

    function disableVolBand(PoolKey calldata key) external onlyOwner {
        PoolId poolId = key.toId();
        VolBand storage band = volBands[poolId];
        band.enabled = false;

        emit VolBandUpdated(poolId, band.centerSqrtPriceX96, band.widthBps, false);
    }

    // Set Max trade guard 
    function setMaxTradeGuard(PoolKey calldata key, uint256 maxAmount) external onlyOwner
    {
        PoolId poolId = key.toId();
        require(isStrategyPool[poolId], "POOL_NOT_STRATEGY");
        require(maxAmount > 0, "INVALID_MAX");

        maxTradeGuards[poolId] = MaxTradeGuard({
            maxAmount: maxAmount,
            enabled: true
        });

        emit MaxTradeGuardUpdated(poolId, maxAmount, true);
    }

    function disableMaxTradeGuard(PoolKey calldata key) external onlyOwner {
        PoolId poolId = key.toId();
        maxTradeGuards[poolId].enabled = false;
        emit MaxTradeGuardUpdated(poolId, maxTradeGuards[poolId].maxAmount, false);
    }

    function configureHook(
        address _vault,
        Currency _baseAsset,
        uint32 _rebalanceCooldown,
        uint32 _rebalanceMaxDuration
    ) external onlyOwner {
        require(_vault != address(0), "VAULT_ZERO");
        require(
            Currency.unwrap(baseAsset) == address(0) || baseAsset == _baseAsset,
            "BASE_ALREADY_SET"
        );

        baseAsset = _baseAsset;

        hookConfig = HookConfig({
            rebalanceCooldown: _rebalanceCooldown,
            rebalanceMaxDuration: _rebalanceMaxDuration,
            vault: _vault
        });

        // reset rebalance state
        rebalanceState = RebalanceState({
            rebalancePending: false,
            nextBatchBlock: 0,
            batchesRemaining: 0,
            lastRebalanceBlock: 0,
            targetAsset: Currency.wrap(address(0))
        });

        emit HookConfigured(
            _vault,
            _baseAsset,
            _rebalanceCooldown,
            _rebalanceMaxDuration
        );
    }

    // Set Toxic Flow Configuration
    function setToxicFlowConfig(
        PoolKey calldata key,
        bool enabled,
        uint32 windowBlocks,
        uint8 maxSameDirLargeTrades,
        uint256 minLargeTradeAmount
    ) external onlyOwner {
        PoolId poolId = key.toId();
        require(isStrategyPool[poolId], "POOL_NOT_STRATEGY");
        require(windowBlocks > 0, "WINDOW_ZERO");
        require(maxSameDirLargeTrades > 0, "MAX_TRADES_ZERO");
        // minLargeTradeAmount can be 0 if you want "all trades" to count

        toxicConfigs[poolId] = ToxicFlowConfig({
            enabled: enabled,
            windowBlocks: windowBlocks,
            maxSameDirLargeTrades: maxSameDirLargeTrades,
            minLargeTradeAmount: minLargeTradeAmount
        });

        emit ToxicFlowConfigUpdated(
            poolId,
            enabled,
            windowBlocks,
            maxSameDirLargeTrades,
            minLargeTradeAmount
        );
    }

    // ========= Admin: pools =========

    function registerStrategyPool(PoolKey calldata key) external onlyOwner {
        PoolId poolId = key.toId();
        isStrategyPool[poolId] = true;
        poolKeys[poolId] = key;
        emit StrategyPoolRegistered(poolId, key.currency0, key.currency1);
    }

    function getRebalancePoolKey(Currency asset) external view returns (PoolKey memory) {
        PoolId poolId = rebalancePool[asset];
        require(PoolId.unwrap(poolId) != bytes32(0), "NO_POOL");
        return poolKeys[poolId];
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

    // ========= Rebalance coordination (vault-driven) =========

    function _rebalanceReady(HookConfig memory cfg, RebalanceState memory st)
        internal
        view
        returns (bool)
    {
        // First rebalance is always allowed
        if (st.lastRebalanceBlock == 0) {
            return true;
        }
        return block.number >= st.lastRebalanceBlock + cfg.rebalanceCooldown;
    }

    /**
     * @notice Called by the vault to start a new rebalance window.
     * The vault has already decided which asset to rebalance and how many batches.
     */
    function startRebalance(Currency targetAsset, uint32 batches)
        external
        onlyVault
        nonReentrant
    {
        HookConfig memory cfg = hookConfig;
        RebalanceState storage st = rebalanceState;

        require(Currency.unwrap(targetAsset) != address(0), "NO_ASSET");
        require(batches > 0, "NO_BATCHES");
        require(_rebalanceReady(cfg, st), "COOLDOWN_ACTIVE");
        require(!st.rebalancePending, "ALREADY_PENDING");

        st.rebalancePending = true;
        st.batchesRemaining = batches;
        st.nextBatchBlock = uint32(block.number);
        st.targetAsset = targetAsset;
    }

    /**
     * @notice Called by the vault AFTER executing the swap for a batch.
     * The vault provides the executed batch parameters for logging.
     */
    function markBatchExecuted(
        PoolKey calldata poolKey,
        bool zeroForOne,
        uint256 amountSpecified
    ) external onlyVault nonReentrant {
        RebalanceState storage st = rebalanceState;

        require(st.rebalancePending, "NO_REBALANCE");
        require(st.batchesRemaining > 0, "NO_BATCHES");
        require(block.number >= st.nextBatchBlock, "TOO_EARLY");

        PoolId poolId = poolKey.toId();

        emit RebalanceBatchPlanned(
            st.targetAsset,
            poolId,
            zeroForOne,
            amountSpecified
        );

        st.batchesRemaining -= 1;

        if (st.batchesRemaining == 0) {
            st.rebalancePending   = false;
            st.lastRebalanceBlock = block.number;
            st.targetAsset        = Currency.wrap(address(0));
            st.nextBatchBlock     = 0;
        } else {
            // simple 1-block spacing; could be parameterized
            st.nextBatchBlock = uint32(block.number + 1);
        }
    }
    // ========= Hook: beforeSwap =========

    /**
     * @notice Checks if rebalance window has expired and clears state if so.
     */
    function _checkAndClearExpiredRebalance() internal {
        RebalanceState storage st = rebalanceState;
        uint32 maxDuration = hookConfig.rebalanceMaxDuration;
        
        if (
            st.rebalancePending &&
            maxDuration > 0 &&
            block.number > st.nextBatchBlock + maxDuration
        ) {
            st.rebalancePending = false;
            st.batchesRemaining = 0;
            st.targetAsset = Currency.wrap(address(0));
            st.nextBatchBlock = 0;
        }
    }

    // ========== Hook : enforce VolBand ===============
    function _enforceVolBand(PoolKey calldata key) internal view {
        PoolId poolId = key.toId(); 
        VolBand storage band = volBands[poolId]; 
        if (!band.enabled) {
            return; 
        }

        (uint160 currentSqrtPriceX96, , , ) = poolManager.getSlot0(poolId);

        // band.widthBps is in BPS around center
        // lower = center * (1 - widthBps/10_000)
        // upper = center * (1 + widthBps/10_000)
        uint256 lower = (uint256(band.centerSqrtPriceX96) * (10_000 - band.widthBps)) / 10_000;
        uint256 upper = (uint256(band.centerSqrtPriceX96) * (10_000 + band.widthBps)) / 10_000;

        require(
            currentSqrtPriceX96 >= lower && currentSqrtPriceX96 <= upper,
            "VOL_BAND_BREACH"
        );
    }

    // ======= Hook : Max Trade Guard  ======== 
    function _enforceMaxTradeGuard(PoolKey calldata key, SwapParams calldata params) internal view {
        MaxTradeGuard memory maxTradeGuard = maxTradeGuards[key.toId()]; 
        if (!maxTradeGuard.enabled) {
            return ;
        } 

        uint256 absAmount = _abs(params.amountSpecified);

        require(absAmount <= maxTradeGuard.maxAmount, "Max Trade"); 
    }

    function _enforceToxicFlowGuard(
        PoolKey calldata key,
        SwapParams calldata params
    ) internal {
        PoolId poolId = key.toId();
        ToxicFlowConfig memory cfg = toxicConfigs[poolId];
        if (!cfg.enabled) {
            return; 
        }

        ToxicFlowState storage st = toxicStates[poolId];

        // Reset window if expired
        if (st.windowStartBlock == 0 || block.number > st.windowStartBlock + cfg.windowBlocks) {
            st.windowStartBlock = uint32(block.number);
            st.sameDirCount = 0;
            // lastZeroForOne can be left as-is; it'll be overwritten on first counted trade
        }

        // Absolute trade size (we don't care about exactInput/output here)
        uint256 absAmount = _abs(params.amountSpecified); 

        // Ignore tiny trades
        if (absAmount < cfg.minLargeTradeAmount) {
            return;
        }

        // Count directional sequence
        if (st.sameDirCount == 0) {
            // first large trade in window
            st.sameDirCount = 1;
            st.lastZeroForOne = params.zeroForOne;
        } else {
            if (params.zeroForOne == st.lastZeroForOne) {
                // same direction as last large trade
                st.sameDirCount += 1;
            } else {
                // direction flipped: start new streak
                st.sameDirCount = 1;
                st.lastZeroForOne = params.zeroForOne;
            }
        }

        require(
            st.sameDirCount <= cfg.maxSameDirLargeTrades,
            "TOXIC_FLOW"
        );
    }



    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Check if the pool is part of the strategy 
        if (!isStrategyPool[key.toId()]) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        RebalanceState storage st = rebalanceState;
        _checkAndClearExpiredRebalance();

        bool isVaultSwap = (sender == hookConfig.vault);

        // Global safeguard (applied to non-vault swaps)
        if (!isVaultSwap){
            // enforce volatility band 
            _enforceVolBand(key); 
            // enforce private max trade 
            _enforceMaxTradeGuard(key, params); 

            // Enforce toxic flow guard during rebalancing period
            if (st.rebalancePending){
                // enforce toxic flow guard 
                _enforceToxicFlowGuard(key, params);
            }
        }

        // If no rebalance happening, nothing special happens
        if (!st.rebalancePending) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Allow vault swaps
        if (isVaultSwap) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }


        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ======== Helpers ==================
    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

}
