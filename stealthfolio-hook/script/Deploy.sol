// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

// Uniswap v4 imports
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

// Hook imports
import {StealthfolioFHEHook} from "../src/hooks/StealthfolioFHEHook.sol";
import {StealthfolioVaultFHE} from "../src/StealthfolioVaultExecutorFHE.sol";

// HookMiner for address mining
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

/// @notice Deployment script for Stealthfolio FHE Hook and Vault on Ethereum Sepolia
/// @dev Usage: forge script script/Deploy.sol:DeployStealthfolio --rpc-url $ETH_SEPOLIA_RPC_URL --chain-id 11155111 --broadcast --verify
/// @dev Test run: forge script script/Deploy.sol:DeployStealthfolio --rpc-url $ETH_SEPOLIA_RPC_URL --chain-id 11155111
contract DeployStealthfolio is Script {
    // CREATE2 Deployer Proxy address (used for deterministic deployments)
    // https://getfoundry.sh/guides/deterministic-deployments-using-create2/#getting-started
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    // Ethereum Sepolia PoolManager address
    // If deploying your own PoolManager, set POOL_MANAGER_ADDRESS env var to empty string
    // Otherwise, set POOL_MANAGER_ADDRESS to the existing PoolManager address on Ethereum Sepolia
    // Note: Uniswap v4 may not be officially deployed on Ethereum Sepolia yet
    IPoolManager public poolManager;

    function setUp() public {
        // You can set POOL_MANAGER_ADDRESS environment variable to use existing PoolManager
        // Example: export POOL_MANAGER_ADDRESS=0x...
        // Otherwise, a new PoolManager will be deployed
        string memory poolManagerAddr = vm.envOr("POOL_MANAGER_ADDRESS", string(""));
        
        if (bytes(poolManagerAddr).length > 0) {
            poolManager = IPoolManager(vm.parseAddress(poolManagerAddr));
            console2.log("Using existing PoolManager at:", address(poolManager));
        } else {
            console2.log("No PoolManager address provided, will deploy new one");
            console2.log("Note: You may need to deploy PoolManager separately if Uniswap v4 is not deployed on Ethereum Sepolia");
        }
    }

    function run() external {
        // Load private key from environment variable
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);

        // Step 1: Deploy or use existing PoolManager
        if (address(poolManager) == address(0)) {
            console2.log("Deploying new PoolManager...");
            poolManager = new PoolManager(msg.sender);
            console2.log("PoolManager deployed at:", address(poolManager));
        }

        // Step 2: Mine for hook address with BEFORE_SWAP_FLAG
        console2.log("Mining for hook address with BEFORE_SWAP_FLAG...");
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        
        bytes memory constructorArgs = abi.encode(poolManager);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(StealthfolioFHEHook).creationCode,
            constructorArgs
        );

        console2.log("Found hook address:", hookAddress);
        console2.log("Salt:", vm.toString(salt));

        // Step 3: Deploy the hook using CREATE2
        console2.log("Deploying StealthfolioFHEHook...");
        StealthfolioFHEHook hook = new StealthfolioFHEHook{salt: salt}(poolManager);
        
        require(address(hook) == hookAddress, "Hook address mismatch");
        console2.log("StealthfolioFHEHook deployed at:", address(hook));

        // Step 4: Deploy the vault
        console2.log("Deploying StealthfolioVaultFHE...");
        StealthfolioVaultFHE vault = new StealthfolioVaultFHE(poolManager, hook);
        console2.log("StealthfolioVaultFHE deployed at:", address(vault));

        // Step 5: Configure the hook with vault address
        // Note: You'll need to call configureHook separately with appropriate parameters
        // This is just a placeholder - you'll need to set:
        // - baseAsset (Currency)
        // - rebalanceCooldown (uint32)
        // - rebalanceMaxDuration (uint32)
        console2.log("\n=== Deployment Summary ===");
        console2.log("PoolManager:", address(poolManager));
        console2.log("StealthfolioFHEHook:", address(hook));
        console2.log("StealthfolioVaultFHE:", address(vault));
        console2.log("\nNext steps:");
        console2.log("1. Configure hook: hook.configureHook(vault, baseAsset, rebalanceCooldown, rebalanceMaxDuration)");
        console2.log("2. Register strategy pools: hook.registerStrategyPool(poolKey)");
        console2.log("3. Set rebalance pools: hook.setRebalancePool(asset, poolKey)");
        console2.log("4. Configure vault strategy: vault.configureEncryptedStrategy(...)");
        console2.log("5. Set portfolio targets: vault.setEncryptedPortfolioTargets(...)");
        console2.log("6. Set price feeds: vault.setPriceFeed(asset, feedAddress)");

        vm.stopBroadcast();
    }
}
