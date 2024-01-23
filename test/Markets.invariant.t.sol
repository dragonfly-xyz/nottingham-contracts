pragma solidity ^0.8;

import { Test } from "forge-std/Test.sol";
import { LibTestUtils as T } from "./LibTestUtils.sol";
import { AssetMarket } from "~/Markets.sol";
import { calcK, clampBuyAmount, clampSellAmount, TestMarket } from "./MarketTestUtils.sol";

contract MultiMarket is Test {
    uint8 immutable MAX_ASSET_COUNT;
    mapping (uint8 assetCount => TestMarket) _marketByAssetCount;
    TestMarket[] _markets;

    constructor(uint8 maxAssetCount) {
        MAX_ASSET_COUNT = maxAssetCount;
    }

    function buyMarket(uint8 marketIdx, uint8 fromIdx, uint8 toIdx, uint256 toAmt)
        external returns (uint256 fromAmt)
    {
        marketIdx = uint8(bound(marketIdx, 0, MAX_ASSET_COUNT));
        TestMarket market = _getOrCreateMarket(marketIdx);
        fromIdx = uint8(bound(fromIdx, 0, marketIdx));
        toIdx = uint8(bound(toIdx, 0, marketIdx));
        // toAmt = bound(toIdx, 0, clampBuyAmount(toAmt, market.reserve(toIdx)));
        return market.buy(fromIdx, toIdx, toAmt);
    }

    function sellMarket(uint8 marketIdx, uint8 fromIdx, uint8 toIdx, uint256 fromAmt)
        external returns (uint256 toAmt)
    {
        marketIdx = uint8(bound(marketIdx, 0, MAX_ASSET_COUNT));
        TestMarket market = _getOrCreateMarket(marketIdx);
        fromIdx = uint8(bound(fromIdx, 0, marketIdx));
        toIdx = uint8(bound(toIdx, 0, marketIdx));
        fromAmt = bound(toIdx, 0, clampSellAmount(fromAmt, market.reserve(fromIdx)));
        return market.sell(fromIdx, toIdx, fromAmt);
    }

    function marketCount() external view returns (uint8) {
        return uint8(_markets.length);
    }

    function getAllMarkets() external view returns (TestMarket[] memory markets) {
        markets = _markets;
    }

    function _getOrCreateMarket(uint8 assetCount) private returns (TestMarket market) {
        market = _marketByAssetCount[assetCount];
        if (address(market) != address(0)) {
            return market;
        }
        uint256[] memory reserves = new uint256[](assetCount);
        for (uint8 i; i < assetCount; ++i) {
            reserves[i] = 100e18 / (10 ** i);
        }
        market = new TestMarket(reserves);
        _markets.push(market);
        _marketByAssetCount[assetCount] = market;
    }
}

contract MarketsInvariantTest is Test {
    MultiMarket markets;
   
    function setUp() external {
        markets = new MultiMarket(5);
    }

    function invariant_K() external {
        TestMarket[] memory markets_ = markets.getAllMarkets();
        for (uint8 i; i < markets_.length; ++i) {
            assertEq(markets_[i].k(), markets_[i].INITIAL_K());
        }
    }
} 