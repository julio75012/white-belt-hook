// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Foundry libraries
import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

// Our contracts
import {LimitOrderHook} from "../src/LimitOrderHook.sol";

contract LimitOrderHookTest is Test, Deployers {
    // Use the libraries
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // The two currencies (tokens) from the pool
    Currency token0;
    Currency token1;

    LimitOrderHook hook;

    function setUp() public {
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();

        // Deploy two test tokens
        (token0, token1) = deployMintAndApprove2Currencies();

        // Deploy our hook
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("LimitOrderHook.sol", abi.encode(manager, ""), hookAddress);
        hook = LimitOrderHook(hookAddress);

        // Approve our hook address to spend these tokens as well
        MockERC20(Currency.unwrap(token0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(hook), type(uint256).max);

        // Initialize a pool with these two tokens
        (key,) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_2);

        // Add initial liquidity to the pool

        // Some liquidity from -60 to +60 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -6960,
                tickUpper: -6900,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // Some liquidity from -120 to +120 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -7020,
                tickUpper: -6780,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // some liquidity for full range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    struct LimitOrderParams {
        int24 tick;
        uint256 amount;
        bool zeroForOne;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function test_placeSellOrder() public {
        // Place a zeroForOne take-profit order
        // for 10e19 token0 tokens
        // at tick 3000
        int24 tick = 3000;
        uint256 amount = 1e19;
        bool zeroForOne = true;

        uint256 originalBalance = token0.balanceOfSelf();

        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        //midprice is at -6932 ticks (because pool is initiated with SQRT_PRICE_1_2)
        assertEq(currentTick, -6932);

        // Place the order
        (int24 tickLower, int24 tickHigher) = hook.placeLimitOrder(key, tick, zeroForOne, amount);

        // Note the new balance of token0 we have
        uint256 newBalance = token0.balanceOfSelf();

        assertEq(tickLower, 3000);
        assertEq(tickHigher, 3060);

        // Ensure that our balance of token0 was reduced by `amount` tokens
        assertEq(originalBalance - newBalance, amount);

        // Check the balance of ERC-1155 tokens we received
        uint256 positionId = hook.getPositionId(key, tickHigher, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);

        // Ensure that we were, in fact, given ERC-1155 tokens for the order
        // equal to the `amount` of token0 tokens we placed the order for
        assertTrue(positionId != 0);
        assertEq(tokenBalance, amount);
    }

    function test_placeBuyOrder() public {
        // Place a zeroForOne take-profit order
        // for 10e19 token0 tokens
        // at tick -6940
        int24 tick = -6940;
        uint256 amount = 1e19;
        bool zeroForOne = false;

        uint256 originalBalance = token1.balanceOfSelf();

        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        //midprice is at -6932 ticks (because pool is initiated with SQRT_PRICE_1_2)
        assertEq(currentTick, -6932);

        // Place the order
        (int24 tickLower, int24 tickHigher) = hook.placeLimitOrder(key, tick, zeroForOne, amount);

        // Note the new balance of token0 we have
        uint256 newBalance = token1.balanceOfSelf();

        assertEq(tickLower, -7020);
        assertEq(tickHigher, -6960);

        // Ensure that our balance of token0 was reduced by `amount` tokens
        assertEq(originalBalance - newBalance, amount);

        // Check the balance of ERC-1155 tokens we received
        uint256 positionId = hook.getPositionId(key, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);

        // Ensure that we were, in fact, given ERC-1155 tokens for the order
        // equal to the `amount` of token0 tokens we placed the order for
        assertTrue(positionId != 0);
        assertEq(tokenBalance, amount);
    }

    function test_cancelLimitOrder() public {
        // Place an order as earlier
        int24 tick = 100;
        uint256 amount = 10e19;
        bool zeroForOne = true;

        uint256 originalBalance = token0.balanceOfSelf();
        (int24 tickLower, int24 tickHigher) = hook.placeLimitOrder(key, tick, zeroForOne, amount);
        uint256 newBalance = token0.balanceOfSelf();

        assertEq(tickLower, 120);
        assertEq(tickHigher, 180);
        assertEq(originalBalance - newBalance, amount);

        // Check the balance of ERC-1155 tokens we received
        uint256 positionId = hook.getPositionId(key, tickHigher, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);
        assertEq(tokenBalance, amount);

        // Cancel the order
        hook.cancelLimitOrder(key, tick, zeroForOne, amount);

        // Check that we received our token0 tokens back, and no longer own any ERC-1155 tokens
        uint256 finalBalance = token0.balanceOfSelf();

        assertApproxEqAbs(
            originalBalance,
            finalBalance,
            100 // error margin for precision loss
        );
        tokenBalance = hook.balanceOf(address(this), positionId);
        assertEq(tokenBalance, 0);
    }

    struct TestState {
        int24 tick;
        uint256 amount;
        bool zeroForOne;
        uint256 originalBalance;
        uint256 newBalance;
        int24 tickLower;
        int24 tickHigher;
        int24 currentTick;
        uint256 positionId;
    }

    function test_cancelLimitOrder_with_price_in_the_middle() public {
        TestState memory state = TestState({
            tick: -6930,
            amount: 10e19,
            zeroForOne: true,
            originalBalance: token0.balanceOfSelf(),
            newBalance: 0,
            tickLower: 0,
            tickHigher: 0,
            currentTick: 0,
            positionId: 0
        });

        // Place a limit order
        state.originalBalance = token0.balanceOfSelf();
        (state.tickLower, state.tickHigher) = hook.placeLimitOrder(key, state.tick, state.zeroForOne, state.amount);
        state.newBalance = token0.balanceOfSelf();

        (, state.currentTick,,) = manager.getSlot0(key.toId());

        assertEq(state.currentTick, -6932);
        assertEq(state.tickLower, -6900);
        assertEq(state.tickHigher, -6840);
        assertEq(state.originalBalance - state.newBalance, state.amount);

        // Place a swap
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !state.zeroForOne,
            amountSpecified: -5 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        int256 deltaSwap0 = int256(token0.balanceOfSelf()); //variable used as a buffer here (it is not a "delta" yet)
        int256 deltaSwap1 = int256(token1.balanceOfSelf()); //variable used as a buffer here (it is not a "delta" yet)

        BalanceDelta deltaSwap = swapRouter.swap(key, swapParams, testSettings, ZERO_BYTES);

        //checking deltas of this swap
        deltaSwap0 = int256(token0.balanceOfSelf()) - deltaSwap0;
        deltaSwap1 = int256(token1.balanceOfSelf()) - deltaSwap1;
        assertEq(deltaSwap0, deltaSwap.amount0());
        assertEq(deltaSwap1, deltaSwap.amount1());

        (, state.currentTick,,) = manager.getSlot0(key.toId());
        //checking that currentTick ends up stricly between lower and higher ticks
        assertEq(state.currentTick, -6895);
        assertEq(state.tickLower, -6900);
        assertEq(state.tickHigher, -6840);

        // Check the balance of ERC-1155 tokens we received
        state.positionId = hook.getPositionId(key, state.tickHigher, state.zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), state.positionId);
        assertEq(tokenBalance, state.amount);

        // Cancel the order
        int256 deltaCancel0 = int256(token0.balanceOfSelf()); //variable used as a buffer here (it is not a "delta" yet)
        int256 deltaCancel1 = int256(token1.balanceOfSelf()); //variable used as a buffer here (it is not a "delta" yet)

        BalanceDelta deltaCancel = hook.cancelLimitOrder(key, state.tick, state.zeroForOne, state.amount);

        //checking that the deltas are correct
        //we observe that the users retrieves a mix of the 2 tokens, which means that only some (but not all) quantitites has been executed
        deltaCancel0 = int256(token0.balanceOfSelf()) - deltaCancel0;
        deltaCancel1 = int256(token1.balanceOfSelf()) - deltaCancel1;
        assertEq(deltaCancel0, deltaCancel.amount0());
        assertEq(deltaCancel1, deltaCancel.amount1());

        // Check that we received our token0 tokens back, and no longer own any ERC-1155 tokens
        tokenBalance = hook.balanceOf(address(this), state.positionId);
        assertEq(tokenBalance, 0);
    }

    function test_orderExecute_zeroForOne() public {
        LimitOrderParams memory limitOrderparams = LimitOrderParams({tick: -6930, amount: 1 ether, zeroForOne: true});

        // Place our order at tick -6935 for 10e18 token0 tokens
        (, int24 tickHigher) =
            hook.placeLimitOrder(key, limitOrderparams.tick, limitOrderparams.zeroForOne, limitOrderparams.amount);

        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        //midprice is at -6932 ticks (because pool is initiated with SQRT_PRICE_1_2)
        assertEq(currentTick, -6932);

        // Do a separate swap from oneForZero to make tick go up
        // Sell 1e18 token1 tokens for token0 tokens
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !limitOrderparams.zeroForOne,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        (, currentTick,,) = manager.getSlot0(key.toId());
        assertEq(currentTick, -6932);

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Conduct the swap - `afterSwap` should also execute our placed order
        swapRouter.swap(key, swapParams, testSettings, ZERO_BYTES);

        (, currentTick,,) = manager.getSlot0(key.toId());
        assertEq(currentTick, -5755);

        // Check that the order has been executed
        // by ensuring no amount is left to sell in the pending orders
        uint256 pendingTokensForPosition =
            hook.pendingOrders(key.toId(), limitOrderparams.tick, limitOrderparams.zeroForOne);
        assertEq(pendingTokensForPosition, 0);

        // Check that the hook contract has the expected number of token1 tokens ready to redeem
        uint256 positionId = hook.getPositionId(key, tickHigher, limitOrderparams.zeroForOne);
        uint256 claimableOutputTokens = hook.claimableOutputTokens(positionId);
        uint256 hookContractToken1Balance = token1.balanceOf(address(hook));
        assertEq(claimableOutputTokens, hookContractToken1Balance);

        // Ensure we can redeem the token1 tokens
        uint256 originalToken1Balance = token1.balanceOf(address(this));
        hook.redeem(key, limitOrderparams.tick, limitOrderparams.zeroForOne, limitOrderparams.amount);
        uint256 newToken1Balance = token1.balanceOf(address(this));
        assertEq(newToken1Balance - originalToken1Balance, claimableOutputTokens);
    }

    function test_orderExecute_oneForZero() public {
        int24 tick = -6933;
        uint256 amount = 1 ether;
        bool zeroForOne = false;

        // Place our order at tick -100 for 10e18 token1 tokens
        (int24 tickLower,) = hook.placeLimitOrder(key, tick, zeroForOne, amount);

        // Do a separate swap from zeroForOne to make tick go down
        // Sell 1e18 token0 tokens for token1 tokens
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -5 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // Check that the order has been executed
        uint256 tokensLeftToSell = hook.pendingOrders(key.toId(), tickLower, zeroForOne);
        assertEq(tokensLeftToSell, 0);

        // Check that the hook contract has the expected number of token0 tokens ready to redeem
        uint256 positionId = hook.getPositionId(key, tickLower, zeroForOne);
        uint256 claimableOutputTokens = hook.claimableOutputTokens(positionId);
        uint256 hookContractToken0Balance = token0.balanceOf(address(hook));
        assertEq(claimableOutputTokens, hookContractToken0Balance);

        // Ensure we can redeem the token0 tokens
        uint256 originalToken0Balance = token0.balanceOfSelf();
        hook.redeem(key, tick, zeroForOne, amount);
        uint256 newToken0Balance = token0.balanceOfSelf();

        assertEq(newToken0Balance - originalToken0Balance, claimableOutputTokens);
    }

    function test_multiple_orderExecute_zeroForOne_onlyOne() public {
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Setup two zeroForOne orders at ticks 0 and 60
        uint256 amount = 0.01 ether;

        (, int24 tickHigher1) = hook.placeLimitOrder(key, -6930, true, amount);
        (, int24 tickHigher2) = hook.placeLimitOrder(key, -6800, true, amount);

        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        assertEq(currentTick, -6932);

        // Do a swap to make tick increase beyond 60
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // Only one order should have been executed
        // because the execution of that order would lower the tick
        // so even though tick increased beyond 60
        // the first order execution will lower it back down
        // so order at tick = 60 will not be executed
        uint256 tokensLeftToSell = hook.pendingOrders(key.toId(), tickHigher1, true);
        assertEq(tokensLeftToSell, 0);

        // Order at Tick 60 should still be pending
        tokensLeftToSell = hook.pendingOrders(key.toId(), tickHigher2, true);
        assertEq(tokensLeftToSell, amount);
    }

    function test_multiple_orderExecute_zeroForOne_both() public {
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Setup two zeroForOne orders at ticks 0 and 60
        uint256 amount = 0.01 ether;

        (, int24 tickHigher1) = hook.placeLimitOrder(key, -6930, true, amount);
        (, int24 tickHigher2) = hook.placeLimitOrder(key, -6800, true, amount);

        // Do a swap to make tick increase
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -0.5 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        uint256 tokensLeftToSell = hook.pendingOrders(key.toId(), tickHigher1, true);
        assertEq(tokensLeftToSell, 0);

        tokensLeftToSell = hook.pendingOrders(key.toId(), tickHigher2, true);
        assertEq(tokensLeftToSell, 0);
    }
}
