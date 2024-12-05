// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries//FixedPoint96.sol";

import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LiquidityAmounts} from "v4-core-test/utils/LiquidityAmounts.sol";
import {Constants} from "v4-core-test/utils/Constants.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {StructuredLinkedList} from "./StructuredLinkedList.sol";

import "forge-std/console.sol";

contract LimitOrderHook is BaseHook, ERC1155 {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;
    using StructuredLinkedList for StructuredLinkedList.List;

    //Constant
    int256 private constant TICK_OFFSET_256 = 887273;
    int24 private constant TICK_OFFSET_24 = 887273;

    // Storage
    mapping(PoolId poolId => int24 lastTick) public lastTicks;
    mapping(PoolId poolId => mapping(int24 tickToSellAt => mapping(bool zeroForOne => uint256 inputAmount))) public
        pendingOrders;
    mapping(PoolId poolId => StructuredLinkedList.List) public bids;
    mapping(PoolId poolId => StructuredLinkedList.List) public asks;

    mapping(uint256 positionId => uint256 outputClaimable) public claimableOutputTokens;
    mapping(uint256 positionId => uint256 claimsSupply) public claimTokensSupply;

    // Errors
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();
    error FailedToAcquireLock();
    error CallerNotManager();

    // Constructor
    constructor(IPoolManager _manager, string memory _uri) BaseHook(_manager) ERC1155(_uri) {}

    // BaseHook Functions
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    struct CallbackData {
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
        address sender;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        lastTicks[key.toId()] = tick;
        return this.afterInitialize.selector;
    }

    function afterSwap(
        address, /*sender*/ //will be useful to reimburse its gas fee...
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        // Should we try to find and execute orders? True initially
        int24 currentTick;

        tryCancellingLiquidity(key);

        // New last known tick for this pool is the tick value
        // after our orders are executed
        lastTicks[key.toId()] = currentTick;
        return (this.afterSwap.selector, 0);
    }

    // Core Hook External Functions
    function placeLimitOrder(PoolKey calldata key, int24 limitOrderTick, bool zeroForOne, uint256 inputAmount)
        external
        returns (int24 lowTick, int24 highTick)
    {
        //get the mid price
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        //checking if the currentTick matches the limitOrderTick and the intention of the user
        //zeroForOne == true -> the users intends to place a ask order (and mid < ask)
        //zeroForOne == false -> the users intends to place an bid order (and bid < mid)
        //limitOrderTick == currentTick also, this case is invalid
        if ((zeroForOne && !(currentTick < limitOrderTick)) || (!zeroForOne && !(limitOrderTick < currentTick))) {
            revert InvalidOrder();
        }

        // Get the smallest tick range on which we will add liquidity
        (lowTick, highTick) = getTickSpaceSegment(limitOrderTick, key.tickSpacing, zeroForOne);

        //we store here the tick price that a swap needs to fully cross in order to cancel the liquidity
        int24 tick = zeroForOne ? highTick : lowTick;

        // Create a pending order
        pendingOrders[key.toId()][tick][zeroForOne] += inputAmount;
        console.log("ok1", tick);

        uint256 sortedTick = uint256(int256(tick) + TICK_OFFSET_256);
        console.log("ok2");
        StructuredLinkedList.List storage list = zeroForOne ? asks[key.toId()] : bids[key.toId()];
        console.log("ok3");
        if (!list.nodeExists(sortedTick)) {
            uint256 tickToInsertAfter = list.getSortedSpot(sortedTick);
            list.insertAfter(tickToInsertAfter, sortedTick);
        }
        console.log("ok4");
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: lowTick,
            tickUpper: highTick,
            liquidityDelta: getLiquidity(inputAmount, lowTick, highTick, zeroForOne),
            salt: bytes32(0)
        });

        console.log("msg.sender 1:", msg.sender);

        poolManager.unlock(abi.encode(CallbackData(key, params, msg.sender)));

        // Mint claim tokens to user equal to their `inputAmount`
        uint256 positionId = getPositionId(key, tick, zeroForOne);
        claimTokensSupply[positionId] += inputAmount;
        _mint(msg.sender, positionId, inputAmount, "");

        // Return the tick at which the order was actually placed
        return (lowTick, highTick);
    }

    function cancelOrder(PoolKey calldata key, int24 limitOrderTick, bool zeroForOne, uint256 amountToCancel)
        external
    {
        // Get the smallest tick range on which we will add liquidity
        (int24 lowTick, int24 highTick) = getTickSpaceSegment(limitOrderTick, key.tickSpacing, zeroForOne);

        //we store here the tick price that a swap needs to fully cross in order to cancel the liquidity
        int24 tick = zeroForOne ? highTick : lowTick;
        uint256 positionId = getPositionId(key, tick, zeroForOne);

        // Check how many claim tokens they have for this position
        uint256 positionTokens = balanceOf(msg.sender, positionId);
        if (positionTokens < amountToCancel) revert NotEnoughToClaim();

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: lowTick,
            tickUpper: highTick,
            liquidityDelta: -getLiquidity(amountToCancel, lowTick, highTick, zeroForOne),
            salt: bytes32(0)
        });

        poolManager.unlock(abi.encode(CallbackData(key, params, msg.sender)));

        //NOTE: I put the liquidity removal before the 'token exchange', making sure it works first.

        // Remove their `amountToCancel` worth of position from pending orders
        pendingOrders[key.toId()][tick][zeroForOne] -= amountToCancel;
        // Reduce claim token total supply and burn their share
        claimTokensSupply[positionId] -= amountToCancel;
        _burn(msg.sender, positionId, amountToCancel);
    }

    function redeem(PoolKey calldata key, int24 limitOrderTick, bool zeroForOne, uint256 inputAmountToClaimFor)
        external
    {
        // Get lower actually usable tick for their order
        (int24 lowTick, int24 highTick) = getTickSpaceSegment(limitOrderTick, key.tickSpacing, zeroForOne);
        int24 tick = zeroForOne ? lowTick : highTick;
        uint256 positionId = getPositionId(key, tick, zeroForOne);

        // If no output tokens can be claimed yet i.e. order hasn't been filled
        // throw error
        if (claimableOutputTokens[positionId] == 0) revert NothingToClaim();

        // they must have claim tokens >= inputAmountToClaimFor
        uint256 positionTokens = balanceOf(msg.sender, positionId);
        if (positionTokens < inputAmountToClaimFor) revert NotEnoughToClaim();

        uint256 totalClaimableForPosition = claimableOutputTokens[positionId];
        uint256 totalInputAmountForPosition = claimTokensSupply[positionId];

        // outputAmount = (inputAmountToClaimFor * totalClaimableForPosition) / (totalInputAmountForPosition)
        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(totalClaimableForPosition, totalInputAmountForPosition);

        // Reduce claimable output tokens amount
        // Reduce claim token total supply for position
        // Burn claim tokens
        claimableOutputTokens[positionId] -= outputAmount;
        claimTokensSupply[positionId] -= inputAmountToClaimFor;
        _burn(msg.sender, positionId, inputAmountToClaimFor);

        // Transfer output tokens
        Currency token = zeroForOne ? key.currency1 : key.currency0;
        token.transfer(msg.sender, outputAmount);
    }

    // Internal Functions
    function tryCancellingLiquidity(PoolKey calldata key) internal {
        // Get current and last tick state
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 lastTick = lastTicks[key.toId()];
        uint256 currentSortedTick = uint256(int256(currentTick) + TICK_OFFSET_256);

        // Determine if price increased and select appropriate order book
        bool isPriceIncreased = currentTick > lastTick;
        StructuredLinkedList.List storage orderBook = isPriceIncreased ? asks[key.toId()] : bids[key.toId()];

        while (true) {
            // Get next order to process
            (bool exists, uint256 nextOrderTick) = isPriceIncreased
                ? orderBook.getNextNode(0) // Get lowest ask
                : orderBook.getPreviousNode(0); // Get highest bid

            // Exit if no more orders or current price hasn't crossed order price
            if (!exists) break;
            if (isPriceIncreased && currentSortedTick < nextOrderTick) break;
            if (!isPriceIncreased && currentSortedTick > nextOrderTick) break;

            // Remove order and get stored amount
            uint256 rawTick = isPriceIncreased
                ? orderBook.popFront() // Pop lowest ask
                : orderBook.popBack(); // Pop highest bid
            int24 storedTick = int24(uint24(rawTick)) - TICK_OFFSET_24;
            uint256 inputAmount = pendingOrders[key.toId()][storedTick][isPriceIncreased];

            // Calculate tick range and cancel liquidity
            (int24 lowTick, int24 highTick) = isPriceIncreased
                ? (storedTick - key.tickSpacing, storedTick)
                : (storedTick, storedTick + key.tickSpacing);

            cancelLiquidity(
                key,
                lowTick,
                highTick,
                isPriceIncreased, // zeroForOne is opposite of price increase
                inputAmount
            );
        }
    }

    function cancelLiquidity(PoolKey calldata key, int24 lowTick, int24 highTick, bool zeroForOne, uint256 inputAmount)
        internal
    {
        // Do the actual swap and settle all balances
        BalanceDelta delta = modifyLiquidityAndSettleBalances(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lowTick,
                tickUpper: highTick,
                liquidityDelta: -getLiquidity(inputAmount, lowTick, highTick, zeroForOne),
                salt: bytes32(0)
            })
        );

        // `inputAmount` has been deducted from this position
        int24 tick = zeroForOne ? lowTick : highTick;
        pendingOrders[key.toId()][tick][zeroForOne] -= inputAmount;
        uint256 positionId = getPositionId(key, tick, zeroForOne);
        uint256 outputAmount = zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));

        // `outputAmount` worth of tokens now can be claimed/redeemed by position holders
        claimableOutputTokens[positionId] += outputAmount;
    }

    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert CallerNotManager();

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta = modifyLiquidityAndSettleBalances(data.key, data.params, data.sender);

        return abi.encode(delta);
    }

    function modifyLiquidityAndSettleBalances(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        address sender
    ) internal returns (BalanceDelta delta) {
        BalanceDelta fee;
        // Conduct the swap inside the Pool Manager
        (delta, fee) = poolManager.modifyLiquidity(key, params, Constants.ZERO_BYTES);

        console.log("fee.amount0(): ", fee.amount0());
        console.log("fee.amount1(): ", fee.amount1());

        if (delta.amount0() < 0) {
            console.log("delta.amount0() < 0 :", delta.amount0());
            _settle(key.currency0, uint128(-delta.amount0()), sender);
        } else if (delta.amount0() > 0) {
            console.log("delta.amount0() > 0 :", delta.amount0());
            _take(key.currency0, uint128(delta.amount0()), sender);
        }
        if (delta.amount1() > 0) {
            _take(key.currency1, uint128(delta.amount1()), sender);
        } else if (delta.amount1() < 0) {
            _settle(key.currency1, uint128(-delta.amount1()), sender);
        }
    }

    function modifyLiquidityAndSettleBalances(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta)
    {
        return modifyLiquidityAndSettleBalances(key, params, address(this));
    }

    // Update _settle function to handle both cases
    function _settle(Currency currency, uint128 amount, address sender) internal {
        poolManager.sync(currency);
        if (sender == address(this)) {
            currency.transfer(address(poolManager), amount);
        } else {
            IERC20(Currency.unwrap(currency)).transferFrom(sender, address(poolManager), amount);
        }
        poolManager.settle();
    }

    function _take(Currency currency, uint128 amount, address sender) internal {
        // Take tokens out of PM to our hook contract
        poolManager.take(currency, sender, amount);
    }

    // Helper Functions
    function getPositionId(PoolKey calldata key, int24 tick, bool zeroForOne) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }

    function getLiquidity(uint256 inputAmount, int24 lowTick, int24 highTick, bool zeroForOne)
        private
        pure
        returns (int256 liquidity)
    {
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(lowTick);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(highTick);

        if (zeroForOne) {
            uint256 intermediate = FullMath.mulDiv(sqrtPriceAX96, sqrtPriceBX96, FixedPoint96.Q96);
            return int256(FullMath.mulDiv(inputAmount, intermediate, sqrtPriceBX96 - sqrtPriceAX96));
        }
        return int256(FullMath.mulDiv(inputAmount, FixedPoint96.Q96, sqrtPriceBX96 - sqrtPriceAX96));
    }

    function getTickSpaceSegment(int24 tick, int24 tickSpacing, bool zeroForOne)
        private
        pure
        returns (int24 low, int24 high)
    {
        // E.g. tickSpacing = 60, tick = -100
        // closest usable tick rounded-down will be -120

        // intervals = -100/60 = -1 (integer division)
        int24 intervals = tick / tickSpacing;

        // since tick < 0, we round `intervals` down to -2
        // if tick > 0, `intervals` is fine as it is
        if (tick < 0 && tick % tickSpacing != 0) intervals--; // round towards negative infinity

        if (zeroForOne && tick % tickSpacing != 0) intervals++; //ask orders are spreaded on the higher end

        //The purpose of this variable is just to save one multiplication later...
        int24 intervalsTimesTickSpacing = intervals * tickSpacing;

        if (zeroForOne) {
            // for a bid order, we want to `spread` it on the lower end
            return (intervalsTimesTickSpacing, intervalsTimesTickSpacing + tickSpacing);
        } else {
            //for an ask order, we want to `spread` it on the higher end
            return (intervalsTimesTickSpacing - tickSpacing, intervalsTimesTickSpacing);
        }
    }
}
