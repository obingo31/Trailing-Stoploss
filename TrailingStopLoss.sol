// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {ERC1155} from "solmate/tokens/ERC1155.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {UniV4UserHook} from "./UniV4UserHook.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import "forge-std/Test.sol";

contract TrailingStopLoss is UniV4UserHook, ERC1155, Test {
    using FixedPointMathLib for uint256;
    using PoolId for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;

    mapping(bytes32 poolId => int24 tickLower) public tickLowerLasts;
    mapping(bytes32 poolId => mapping(int24 tick => mapping(bool zeroForOne => int256 amount))) public stopLossPositions;

    // Mapping to store trailing stop-loss data
    mapping(bytes32 poolId => int24 trailingStopTick) public trailingStopTicks;

    // -- 1155 state -- //
    mapping(uint256 tokenId => TokenIdData) public tokenIdIndex;
    mapping(uint256 tokenId => bool) public tokenIdExists;
    mapping(uint256 tokenId => uint256 claimable) public claimable;
    mapping(uint256 tokenId => uint256 supply) public totalSupply;

    struct TokenIdData {
        IPoolManager.PoolKey poolKey;
        int24 tickLower;
        bool zeroForOne;
    }

    // constants for sqrtPriceLimitX96 which allow for unlimited impact
    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_RATIO + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_RATIO - 1;

    constructor(IPoolManager _poolManager) UniV4UserHook(_poolManager) {}

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: true,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    function afterInitialize(address, IPoolManager.PoolKey calldata key, uint160, int24 tick)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        setTickLowerLast(key.toId(), getTickLower(tick, key.tickSpacing));
        return TrailingStopLoss.afterInitialize.selector;
    }

    function afterSwap(
        address,
        IPoolManager.PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta
    ) external override returns (bytes4) {
        int24 prevTick = tickLowerLasts[key.toId()];
        (, int24 tick,) = poolManager.getSlot0(key.toId());
        int24 currentTick = getTickLower(tick, key.tickSpacing);
        tick = prevTick;

        int256 swapAmounts;

        bool stopLossZeroForOne = !params.zeroForOne;

        // Update trailing stop-loss if the market moves favorably
        if (stopLossZeroForOne && currentTick > trailingStopTicks[key.toId()]) {
            trailingStopTicks[key.toId()] = currentTick;
        } else if (!stopLossZeroForOne && currentTick < trailingStopTicks[key.toId()]) {
            trailingStopTicks[key.toId()] = currentTick;
        }

        if (prevTick < currentTick) {
            for (; tick < currentTick;) {
                swapAmounts = stopLossPositions[key.toId()][tick][stopLossZeroForOne];
                if (swapAmounts > 0) {
                    fillStopLoss(key, tick, stopLossZeroForOne, swapAmounts);
                }
                unchecked {
                    tick += key.tickSpacing;
                }
            }
        } else {
            for (; currentTick < tick;) {
                swapAmounts = stopLossPositions[key.toId()][tick][stopLossZeroForOne];
                if (swapAmounts > 0) {
                    fillStopLoss(key, tick, stopLossZeroForOne, swapAmounts);
                }
                unchecked {
                    tick -= key.tickSpacing;
                }
            }
        }
        return TrailingStopLoss.afterSwap.selector;
    }

    function fillStopLoss(IPoolManager.PoolKey calldata poolKey, int24 triggerTick, bool zeroForOne, int256 swapAmount)
        internal
    {
        IPoolManager.SwapParams memory stopLossSwapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        BalanceDelta delta = UniV4UserHook.swap(poolKey, stopLossSwapParams, address(this));
        stopLossPositions[poolKey.toId()][triggerTick][zeroForOne] -= swapAmount;

        uint256 tokenId = getTokenId(poolKey, triggerTick, zeroForOne);

        uint256 amount = zeroForOne ? uint256(int256(-delta.amount1())) : uint256(int256(-delta.amount0()));
        claimable[tokenId] += amount;
    }

    function placeStopLoss(IPoolManager.PoolKey calldata poolKey, int24 tickLower, uint256 amountIn, bool zeroForOne)
        external
        returns (int24 tick)
    {
        tick = getTickLower(tickLower, poolKey.tickSpacing);

        stopLossPositions[poolKey.toId()][tick][zeroForOne] += int256(amountIn);

        uint256 tokenId = getTokenId(poolKey, tick, zeroForOne);
        if (!tokenIdExists[tokenId]) {
            tokenIdExists[tokenId] = true;
            tokenIdIndex[tokenId] = TokenIdData({poolKey: poolKey, tickLower: tick, zeroForOne: zeroForOne});
        }
        _mint(msg.sender, tokenId, amountIn, "");
        totalSupply[tokenId] += amountIn;

        address token = zeroForOne ? Currency.unwrap(poolKey.currency0) : Currency.unwrap(poolKey.currency1);
        IERC20(token).transferFrom(msg.sender, address(this), amountIn);

        // Initialize trailing stop-loss
        trailingStopTicks[poolKey.toId()] = tick;
    }

    function killStopLoss() external {}

    function uri(uint256) public pure override returns (string memory) {
        return "https://example.com";
    }

    function getTokenId(IPoolManager.PoolKey calldata poolKey, int24 tickLower, bool zeroForOne)
        public
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encodePacked(poolKey.toId(), tickLower, zeroForOne)));
    }

    function redeem(uint256 tokenId, uint256 amountIn, address destination) external {
        require(claimable[tokenId] > 0, "StopLoss: no claimable amount");
        uint256 receiptBalance = balanceOf[msg.sender][tokenId];
        require(amountIn <= receiptBalance, "StopLoss: not enough tokens to redeem");

        TokenIdData memory data = tokenIdIndex[tokenId];
        address token =
            data.zeroForOne ? Currency.unwrap(data.poolKey.currency1) : Currency.unwrap(data.poolKey.currency0);

        uint256 amountOut = amountIn.mulDivDown(claimable[tokenId], totalSupply[tokenId]);
        claimable[tokenId] -= amountOut;
        _burn(msg.sender, tokenId, amountIn);
        totalSupply[tokenId] -= amountIn;

        IERC20(token).transfer(destination, amountOut);
    }

    function setTickLowerLast(bytes32 poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function getTickLower(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }
}
