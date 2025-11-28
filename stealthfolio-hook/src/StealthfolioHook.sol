


// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Open Zeppelin imports
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// Uniswap v4 imports
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey, PoolIdLibrary} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";


contract StealthfolioHook is BaseHook, Ownable{
    using PoolIdLibrary for PoolKey;


    constructor(IPoolManager _manager) BaseHook(_manager) Ownable(msg.sender) {
        
    }

    // Hook Permissions 
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
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

    /// @notice Configure a portfolio strategy for a specific pool.
    /// For v1 POC, onlyOwner can call this.
    function createStrategy(
        uint256 portfolioId,
        PoolKey calldata key,
        address vault,
        address executor,
        uint16 targetBpsToken0,
        uint16 minDriftBps,
        uint16 batchSizeBps,
        uint32 rebalanceCooldown,
        uint16 maxExternalSwapBps,
        int256 initialPosToken0,
        int256 initialPosToken1
    ) external onlyOwner {
        require(strategies[portfolioId].vault == address(0), "STRATEGY_EXISTS");
        require(targetBpsToken0 <= 10_000, "BAD_TARGET");
        require(batchSizeBps > 0 && batchSizeBps <= 10_000, "BAD_BATCH");

        PoolId poolId = key.toId();
        require(poolPortfolio[poolId] == 0, "POOL_ALREADY_USED");

        strategies[portfolioId] = StrategyConfig({
            targetBpsToken0: targetBpsToken0,
            targetBpsToken1: uint16(10_000 - targetBpsToken0),
            minDriftBps:     minDriftBps,
            batchSizeBps:    batchSizeBps,
            rebalanceCooldown: rebalanceCooldown,
            maxExternalSwapBps: maxExternalSwapBps,
            vault: vault,
            executor: executor
        });

        strategyStates[portfolioId] = StrategyState({
            posToken0: initialPosToken0,
            posToken1: initialPosToken1,
            deltaToken0: 0,
            deltaToken1: 0,
            lastDriftBps: 0,
            rebalancePending: false,
            rebalanceActive: false,
            nextBatchBlock: 0,
            batchesRemaining: 0,
            lastRebalanceBlock: block.number
        });

        poolPortfolio[poolId] = portfolioId;
        portfolioPool[portfolioId] = key;
    }


        struct StrategyConfig {
        uint16 targetBpsToken0;     // e.g. 6000 = 60%
        uint16 targetBpsToken1;     // 10000 - targetBpsToken0
        uint16 minDriftBps;         // minimum drift to trigger rebalance
        uint16 batchSizeBps;        // % of delta per batch (e.g. 2500 = 25%)
        uint32 rebalanceCooldown;   // blocks between full rebalances
        uint16 maxExternalSwapBps;  // placeholder (v1 uses a fixed absolute cap)
        address vault;              // address that holds funds (EOA or contract)
        address executor;           // keeper / bot that calls rebalance functions
    }

    struct StrategyState {
        int256 posToken0;           // virtual position in token0
        int256 posToken1;           // virtual position in token1

        int256 deltaToken0;         // last computed delta (target - pos)
        int256 deltaToken1;
        uint16 lastDriftBps;        // last drift value

        bool rebalancePending;      // drift exceeded, batches not yet finished
        bool rebalanceActive;       // currently executing a batch (optional flag)

        uint32 nextBatchBlock;      // earliest block for next batch
        uint32 batchesRemaining;    // how many batches left in this sequence
        uint256 lastRebalanceBlock; // last fully completed rebalance
    }

    // portfolioId (strategyId) => config & state
    mapping(uint256 => StrategyConfig) public strategies;
    mapping(uint256 => StrategyState)  public strategyStates;

    // pool ↔ portfolio mapping (v1: one portfolio per pool)
    mapping(PoolId => uint256)  public poolPortfolio;   // poolId => portfolioId
    mapping(uint256 => PoolKey) public portfolioPool;   // portfolioId => PoolKey

    // Hooks functionalities
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata, // params (unused in v1 telemetry)
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        uint256 portfolioId = poolPortfolio[poolId];

        // If this pool isn't attached to any portfolio, ignore.
        if (portfolioId == 0) {
            return (BaseHook.afterSwap.selector, 0);
        }

        StrategyState storage st = strategyStates[portfolioId];

        // BalanceDelta is from pool's POV. We treat it as portfolio exposure change.
        st.posToken0 += int256(delta.amount0());
        st.posToken1 += int256(delta.amount1());

        // Optionally, if sender == vault && rebalanceActive, you could update
        // fine-grained progress here. For v1 we keep it simple.

        return (BaseHook.afterSwap.selector, 0);
    }

    /// @notice Called by executor to check drift and mark a rebalance if needed.
    function checkAndMarkRebalance(uint256 portfolioId) external {
        StrategyConfig storage cfg = strategies[portfolioId];
        StrategyState  storage st  = strategyStates[portfolioId];

        require(cfg.vault != address(0), "NO_STRATEGY");
        require(msg.sender == cfg.executor, "NOT_EXECUTOR");

        // Cooldown: avoid too-frequent rebalances
        if (block.number < st.lastRebalanceBlock + cfg.rebalanceCooldown) {
            return;
        }

        int256 pos0 = st.posToken0;
        int256 pos1 = st.posToken1;
        require(pos0 >= 0 && pos1 >= 0, "NEG_POS");

        uint256 total = uint256(pos0) + uint256(pos1);
        if (total == 0) {
            // No exposure = nothing to rebalance
            return;
        }

        // Compute targets (v1 simplification: tokens treated as same notional units)
        uint256 target0 = total * cfg.targetBpsToken0 / 10_000;
        uint256 target1 = total * cfg.targetBpsToken1 / 10_000;

        // Signed deviations: target - current
        int256 dev0 = int256(target0) - pos0;
        int256 dev1 = int256(target1) - pos1;

        // Drift in basis points
        uint256 drift0 = _abs(dev0) * 10_000 / total;
        uint256 drift1 = _abs(dev1) * 10_000 / total;
        uint16 driftBps = uint16(_max(drift0, drift1));

        st.lastDriftBps = driftBps;

        if (driftBps < cfg.minDriftBps) {
            // below threshold; do nothing
            return;
        }

        // Mark rebalance needed
        st.deltaToken0 = dev0;
        st.deltaToken1 = dev1;
        st.rebalancePending = true;
        st.rebalanceActive  = false;

        // Decide how many batches based on the larger absolute delta
        uint256 maxAbsDelta = _max(_abs(dev0), _abs(dev1));
        uint32 batches = uint32((maxAbsDelta * 10_000 + cfg.batchSizeBps - 1) / cfg.batchSizeBps);
        if (batches == 0) batches = 1;

        st.batchesRemaining = batches;
        st.nextBatchBlock   = uint32(block.number);
    }

        /// @notice Compute direction & amount for the next batch given current deltas.
    function _computeBatchParams(
        StrategyConfig storage cfg,
        StrategyState  storage st
    ) internal view returns (bool zeroForOne, uint256 amountSpecified) {
        uint256 abs0 = _abs(st.deltaToken0);
        uint256 abs1 = _abs(st.deltaToken1);

        // Trade the token with the larger deviation
        bool tradeToken0 = abs0 >= abs1;

        int256 delta = tradeToken0 ? st.deltaToken0 : st.deltaToken1;
        uint256 absDelta = _abs(delta);

        // batch = absDelta * batchSizeBps / 10_000
        uint256 batch = absDelta * cfg.batchSizeBps / 10_000;
        if (batch == 0) {
            batch = absDelta; // final tiny batch = clear remainder
        }

        // Direction:
        // If we have too much token0 (delta0 < 0), we sell token0: zeroForOne = true
        if (tradeToken0) {
            zeroForOne = (delta < 0);
        } else {
            // If we have too much token1 (delta1 < 0), we sell token1.
            // In Uniswap v4, zeroForOne=true means token0->token1.
            // For token1->token0 we use zeroForOne=false.
            zeroForOne = (delta >= 0); // depends on how you want to encode; adjust as needed.
        }

        amountSpecified = batch;
    }

        /// @notice View helper for off-chain / router: get planned next batch.
    function getNextBatch(uint256 portfolioId)
        external
        view
        returns (bool canExecute, bool zeroForOne, uint256 amountSpecified)
    {
        StrategyConfig storage cfg = strategies[portfolioId];
        StrategyState  storage st  = strategyStates[portfolioId];

        if (!st.rebalancePending || st.batchesRemaining == 0) {
            return (false, false, 0);
        }
        if (block.number < st.nextBatchBlock) {
            return (false, false, 0);
        }

        (bool zf1, uint256 amt) = _computeBatchParams(cfg, st);
        return (true, zf1, amt);
    }

        event RebalanceBatchPlanned(
        uint256 indexed portfolioId,
        bool zeroForOne,
        uint256 amountSpecified
    );

    /// @notice Called by executor *after* performing the swap off-chain/on-chain.
    /// It advances the rebalance state machine (batchesRemaining, cooldown, etc).
    function markBatchExecuted(uint256 portfolioId) external {
        StrategyConfig storage cfg = strategies[portfolioId];
        StrategyState  storage st  = strategyStates[portfolioId];

        require(msg.sender == cfg.executor, "NOT_EXECUTOR");
        require(st.rebalancePending, "NO_REBALANCE");
        require(st.batchesRemaining > 0, "NO_BATCHES");
        require(block.number >= st.nextBatchBlock, "TOO_EARLY");

        (bool zeroForOne, uint256 amountSpecified) = _computeBatchParams(cfg, st);

        // Emit for visibility / off-chain indexing
        emit RebalanceBatchPlanned(portfolioId, zeroForOne, amountSpecified);

        st.batchesRemaining -= 1;

        if (st.batchesRemaining == 0) {
            st.rebalancePending = false;
            st.rebalanceActive  = false;
            st.lastRebalanceBlock = block.number;
        } else {
            st.nextBatchBlock = uint32(block.number + 1); // or from config if you add minDelayBlocks
        }
    }


        function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        uint256 portfolioId = poolPortfolio[poolId];
        if (portfolioId == 0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA , 0);
        }

        StrategyConfig storage cfg = strategies[portfolioId];
        StrategyState  storage st  = strategyStates[portfolioId];

        // Only guard when a rebalance is in flight or pending
        if (!st.rebalancePending && !st.rebalanceActive) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA , 0);
        }

        // Vault swaps are always allowed — they *are* the rebalance.
        if (sender == cfg.vault) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA , 0);
        }

        // For others: enforce a maximum external swap size.
        uint256 absAmount = params.amountSpecified > 0
            ? uint256(params.amountSpecified)
            : uint256(-params.amountSpecified);

        // v1: simple fixed cap. You can tie this to liquidity / total later.
        uint256 MAX_EXTERNAL_AMOUNT = 1e18; // e.g. 1 token unit (adjust in tests)

        require(absAmount <= MAX_EXTERNAL_AMOUNT, "REBAL_PROTECTED");

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA , 0);
    }





    // Helper Functions 
    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }



}
