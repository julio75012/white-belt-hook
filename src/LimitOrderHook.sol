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

import "forge-std/console.sol";

contract LimitOrderHook is BaseHook, ERC1155 {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    // Storage
    mapping(PoolId poolId => int24 lastTick) public lastTicks;
    mapping(PoolId poolId => mapping(int24 tickToSellAt => mapping(bool zeroForOne => uint256 inputAmount))) public
        pendingOrders;

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
        bool tryMore = true;
        int24 currentTick;

        while (tryMore) {
            (tryMore, currentTick) = tryCancellingLiquidity(key);
        }

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
        //zeroForOne == false -> the users intends to place an ask order (and bid < mid)
        //limitOrderTick == currentTick also, this case is invalid
        if ((zeroForOne && limitOrderTick <= currentTick) || (!zeroForOne && currentTick <= limitOrderTick)) {
            revert InvalidOrder();
        }

        // Get the smallest tick range on which we will add liquidity
        (lowTick, highTick) = getTickSpaceSegment(limitOrderTick, key.tickSpacing, zeroForOne);

        //we store here the tick price that a swap needs to fully cross in order to cancel the liquidity
        int24 tick = zeroForOne ? highTick : lowTick;

        // Create a pending order
        pendingOrders[key.toId()][tick][zeroForOne] += inputAmount;
        //TODO: get the high or low tick back with a function (using the tickspace)

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
        int24 tick = zeroForOne ? lowTick : highTick;
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

        // Send them their input token
        Currency token = zeroForOne ? key.currency0 : key.currency1;

        token.transfer(msg.sender, amountToCancel);
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
    function tryCancellingLiquidity(PoolKey calldata key) internal returns (bool tryMore, int24 newTick) {
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 lastTick = lastTicks[key.toId()];

        // if the price increased, we are looking to cancel the liquidity having a high tick that got crossed
        // here zeroForOne = false, we are cancelling orders inteding to sell 1 and buy 0
        if (currentTick > lastTick) {
            for (int24 highTick = lastTick; highTick < currentTick; highTick += key.tickSpacing) {
                uint256 inputAmount = pendingOrders[key.toId()][highTick][false];
                if (inputAmount > 0) {
                    int24 lowTick = highTick - key.tickSpacing;
                    cancelLiquidity(key, lowTick, highTick, false, inputAmount);
                }
            }
        } else {
            // if the price decreased, we are looking to cancel the liquidity having a low tick that got crossed
            // here zeroForOne = true, we are cancelling orders inteding to buy 1 and sell 0
            for (int24 lowTick = lastTick; lowTick > currentTick; lowTick -= key.tickSpacing) {
                uint256 inputAmount = pendingOrders[key.toId()][lowTick][true];
                if (inputAmount > 0) {
                    int24 highTick = lowTick + key.tickSpacing;
                    cancelLiquidity(key, lowTick, highTick, true, inputAmount);
                }
            }
        }

        return (false, currentTick);
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

    function modifyLiquidityAndSettleBalances(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        // Conduct the swap inside the Pool Manager
        (delta,) = poolManager.modifyLiquidity(key, params, Constants.ZERO_BYTES);
        console.log("msg.sender 4:", msg.sender);

        if (delta.amount0() < 0) {
            console.log("delta.amount0() < 0");
            _settle(key.currency0, uint128(-delta.amount0()));
        } else if (delta.amount0() > 0) {
            console.log("delta.amount0() > 0");
            _take(key.currency0, uint128(delta.amount0()));
        }
        if (delta.amount1() > 0) {
            console.log("delta.amount1() > 0");
            _take(key.currency1, uint128(delta.amount1()));
        } else if (delta.amount1() < 0) {
            console.log("delta.amount1() < 0");
            _settle(key.currency1, uint128(-delta.amount1()));
        }
    }

    function modifyLiquidityAndSettleBalances(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        address sender
    ) internal returns (BalanceDelta delta) {
        // Conduct the swap inside the Pool Manager
        (delta,) = poolManager.modifyLiquidity(key, params, Constants.ZERO_BYTES);
        console.log("msg.sender 2:", msg.sender);
        console.log("msg.sender 3:", sender);

        if (delta.amount0() < 0) {
            console.log("delta.amount0() < 0");
            console.log(delta.amount0());
            _settle(key.currency0, uint128(-delta.amount0()), sender);
        } else if (delta.amount0() > 0) {
            console.log("delta.amount0() > 0");
            _take(key.currency0, uint128(delta.amount0()));
        }
        if (delta.amount1() > 0) {
            console.log("delta.amount1() > 0");
            _take(key.currency1, uint128(delta.amount1()));
        } else if (delta.amount1() < 0) {
            console.log("delta.amount1() < 0");
            _settle(key.currency1, uint128(-delta.amount1()), sender);
        }
    }

    function _settle(Currency currency, uint128 amount, address sender) internal {
        // Transfer tokens to PM and let it know
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).transferFrom(sender, address(poolManager), amount);
        poolManager.settle();
    }

    function _settle(Currency currency, uint128 amount) internal {
        // Transfer tokens to PM and let it know
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _take(Currency currency, uint128 amount) internal {
        // Take tokens out of PM to our hook contract
        poolManager.take(currency, address(this), amount);
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
