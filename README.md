# Uniswap v4 Limit Order Hook

A custom Uniswap v4 Hook that implements limit order functionality, allowing users to place, cancel, and execute limit orders directly on-chain.

## Overview

This hook enables limit order functionality in Uniswap v4 pools by leveraging the hook system. Users can place both buy and sell limit orders at specific price points (ticks), and these orders are automatically executed when the market price crosses their specified price level.

## Features

- **Limit Order Placement**: Place buy or sell orders at specific price points
- **Order Cancellation**: Cancel existing orders and retrieve original tokens
- **Automatic Execution**: Orders are automatically executed when price conditions are met
- **ERC-1155 Tokenized Positions**: Order positions are represented as ERC-1155 tokens
- **Sorted Order Books**: Maintains separate sorted lists for bids and asks
- **Partial Fill Support**: Orders can be partially filled and claimed

## YouTube Demo & Explanation

[YouTube Uniswap v4 Limit Order Hook Explanation](https://www.youtube.com/watch?v=VMt0i9OPEzY)

Click the link above to watch the explanation video on YouTube.

## Technical Details

### Core Components

1. **LimitOrderHook.sol**: Main contract implementing the limit order functionality
   - Inherits from `BaseHook` and `ERC1155`
   - Implements Uniswap v4's hook interface
   - Manages order books and execution logic

2. **StructuredLinkedList.sol**: Helper contract for maintaining sorted order books
   - Implements a doubly-linked list with sorting capabilities
   - Used to track and process orders efficiently

### Key Functions

```solidity
function placeLimitOrder(
PoolKey calldata key,
int24 limitOrderTick,
bool zeroForOne,
uint256 inputAmount
) external returns (int24 lowTick, int24 highTick)
```

Places a new limit order at the specified tick price.

```solidity
function cancelLimitOrder(
PoolKey calldata key,
int24 limitOrderTick,
bool zeroForOne,
uint256 amountToCancel
) external
```

Cancels an existing limit order and returns the original tokens.

```solidity
function redeem(
PoolKey calldata key,
int24 limitOrderTick,
bool zeroForOne,
uint256 inputAmountToClaimFor
) external
```

Claims tokens after a successful order execution.

## How It Works

1. **Order Placement**
   - User specifies a price (tick) and amount for their order
   - Tokens are transferred to the hook contract
   - User receives ERC-1155 tokens representing their position
   - Order is added to the appropriate sorted list (bids or asks)

2. **Order Execution**
   - Triggered automatically during Uniswap swaps via the `afterSwap` hook
   - Orders are executed when market price crosses the limit price
   - Executed orders are removed from the order book
   - Output tokens become claimable by position holders

3. **Order Cancellation**
   - Users can cancel orders at any time before execution
   - Original tokens are returned to the user
   - Position tokens are burned
   - Order is removed from the order book

## Testing

The repository includes comprehensive tests covering:
- Order placement (both buy and sell orders)
- Order cancellation
- Order execution
- Multiple order scenarios
- Edge cases

Run tests using Forge:

```bash
forge test
```

## Installation

1. Clone the repository:

```bash
git clone https://github.com/julio75012/white-belt-hook
```

2. Install dependencies:

```bash
forge install
```

## Requirements

- Foundry/Forge
- Solidity ^0.8.0
- Uniswap v4 core contracts

## Security Considerations

- The contract handles user funds and should be thoroughly audited before production use
- Price manipulation risks should be considered
- Gas optimization for order execution is important
- Proper access controls and input validation are crucial

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Disclaimer

This code is provided as-is and has not been audited. Use at your own risk.
