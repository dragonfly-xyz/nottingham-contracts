pragma solidity ^0.8;

import {
    AssetMarket,
    MIN_LIQUIDITY_PER_RESERVE,
    MAX_LIQUIDITY_PER_RESERVE
} from "~/Markets.sol";

uint256 constant MIN_PRECISION = 1e4;

function calcK(uint256[] memory reserves) pure returns (uint256 k) {
    uint256[] memory reserves_ = new uint256[](reserves.length);
    for (uint256 i; i < reserves.length; ++i) {
        reserves_[i] = reserves[i];
    }
    k = 1e18;
    uint256 remainingCount = reserves_.length;
    while (remainingCount != 0) {
        for (uint256 i; i < reserves_.length; ++i) {
            uint256 r = reserves_[i];
            if (r == 0) {
                continue;
            }
            if (k * r / 1e18 >= MIN_PRECISION) {
                k = k * r / 1e18;
                --remainingCount;
                reserves_[i] = 0;
            } else {
                // Precision would be too low, come back to it later (hopefully).
            }
        }
    }
}

function clampSellAmount(uint256 sellAmount, uint256 reserveAmount)
    pure returns (uint256 sellAmount_)
{
    if (reserveAmount >= MAX_LIQUIDITY_PER_RESERVE) {
        return 0;
    }
    uint256 sellableAmount = MAX_LIQUIDITY_PER_RESERVE - reserveAmount;
    if (sellAmount > sellableAmount) {
        return sellableAmount;
    }
    return sellAmount;
}

function clampBuyAmount(uint256 buyAmount, uint256 reserveAmount)
    pure returns (uint256 buyAmount_)
{
    if (reserveAmount <= MIN_LIQUIDITY_PER_RESERVE) {
        return 0;
    }
    uint256 buyableAmount = reserveAmount - MIN_LIQUIDITY_PER_RESERVE;
    if (buyAmount > buyableAmount) {
        return buyableAmount;
    }
    return buyAmount;
}

function createTestMarket(uint8 assetCount) returns (TestMarket market) {
    uint256[] memory reserves = new uint256[](assetCount);
    for (uint8 i; i < assetCount; ++i) {
        reserves[i] = 100e18 / (10 ** i);
    }
    market = new TestMarket(reserves);
}

contract TestMarket is AssetMarket {
    uint256 public immutable INITIAL_K;
    
    constructor(uint256[] memory reserves) AssetMarket(uint8(reserves.length)) {
        _init(reserves);
        INITIAL_K = calcK(reserves);
    }

    function buy(uint8 fromIdx, uint8 toIdx, uint256 toAmt)
        external returns (uint256 fromAmt)
    {
        return _buy(fromIdx, toIdx, toAmt);
    }

    function sell(uint8 fromIdx, uint8 toIdx, uint256 fromAmt)
        external returns (uint256 toAmt)
    {
        return _sell(fromIdx, toIdx, fromAmt);
    }

    function reserve(uint8 idx) external view returns (uint256) {
        return _getReserve(idx);
    }

    function quoteBuy(uint8 fromIdx, uint8 toIdx, uint256 toAmt)
        external view returns (uint256 fromAmt)
    {
        return _quoteBuy(fromIdx, toIdx, toAmt);
    }

    function quoteSell(uint8 fromIdx, uint8 toIdx, uint256 fromAmt)
        external view returns (uint256 toAmt)
    {
        return _quoteSell(fromIdx, toIdx, fromAmt);
    }

    function k() external view returns (uint256 k_) {
        uint256[] memory reserves = new uint256[](ASSET_COUNT);
        for (uint8 i; i < ASSET_COUNT; ++i) {
            reserves[i] = _getReserve(i);
        }
        return calcK(reserves);
    }
}
