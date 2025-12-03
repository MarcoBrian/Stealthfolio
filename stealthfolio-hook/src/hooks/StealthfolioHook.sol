// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// OpenZeppelin
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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

contract StealthfolioHook is BaseHook, Ownable, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;


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
        uint256 maxExternalSwapAmount; // max external swap size during rebalance (per swap)
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

    // ========= Events =========

    event HookConfigured(
        address indexed vault,
        Currency baseAsset,
        uint32 rebalanceCooldown,
        uint32 rebalanceMaxDuration,
        uint256 maxExternalSwapAmount
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

    function configureHook(
        address _vault,
        Currency _baseAsset,
        uint32 _rebalanceCooldown,
        uint32 _rebalanceMaxDuration,
        uint256 _maxExternalSwapAmount
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
            maxExternalSwapAmount: _maxExternalSwapAmount,
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
            _rebalanceMaxDuration,
            _maxExternalSwapAmount
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
    // ========= Hook: beforeSwap (drift guard) =========

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

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (!isStrategyPool[key.toId()]) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        RebalanceState storage st = rebalanceState;
        _checkAndClearExpiredRebalance();

        if (!st.rebalancePending) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Vault swaps are always allowed
        if (sender == hookConfig.vault) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // For external traders, limit max order size during rebalance
        uint256 absAmount = params.amountSpecified > 0
            ? uint256(params.amountSpecified)
            : uint256(-params.amountSpecified);
        require(absAmount <= hookConfig.maxExternalSwapAmount, "REBAL_PROTECTED");

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
