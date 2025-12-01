// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {StealthfolioHook} from "./hooks/StealthfolioHook.sol";

contract StealthfolioVault is Ownable {
    IPoolManager public immutable manager;
    StealthfolioHook public immutable hook;

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
    // Rebalance: Main Step
    // ======================

    /**
     * @notice Performs ONE rebalance batch:
     *  1. Fetch/mint prices (POC: mock prices)
     *  2. hook.checkAndMarkRebalance()
     *  3. hook.getNextBatch()
     *  4. Execute swap with PoolManager
     *  5. hook.markBatchExecuted()
     */
    function rebalanceStep(uint256[] calldata pricesInBase) external onlyOwner {
        // 1. Mark drift
        hook.checkAndMarkRebalance(pricesInBase);

        // 2. Fetch batch params
        (bool canExec, PoolKey memory key, bool zeroForOne, uint256 amountSpecified)
            = hook.getNextBatch();

        if (!canExec || amountSpecified == 0) {
            return;
        }

        // 3. Approve tokens if needed
        _approveIfNeeded(key, amountSpecified, zeroForOne);

        // 4. Execute swap through PoolManager
        _executeSwap(key, zeroForOne, amountSpecified);

        // 5. Notify hook
        hook.markBatchExecuted();
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
