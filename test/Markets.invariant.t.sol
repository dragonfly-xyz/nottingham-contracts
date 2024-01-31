pragma solidity ^0.8;

import { Test } from "forge-std/Test.sol";
import { LibTestUtils as T } from "./LibTestUtils.sol";
import { AssetMarket } from "~/Markets.sol";
import { calcK, clampBuyAmount, clampSellAmount, TestMarket, createTestMarket } from "./MarketTestUtils.sol";

contract MultiMarket is Test {
    uint8 immutable MAX_ASSET_COUNT;
    mapping (uint8 assetCount => TestMarket) _marketByAssetCount;
    TestMarket[] _markets;

    constructor(uint8 maxAssetCount) {
        MAX_ASSET_COUNT = maxAssetCount;
        for (uint8 i = 2; i <= maxAssetCount; ++i) {
            TestMarket market = createTestMarket(i);
            _markets.push(market);
            _marketByAssetCount[i] = market;
        }
    }

    function buyMarket(uint8 assetCount, uint8 fromIdx, uint8 toIdx, uint256 toAmt)
        external returns (uint256 fromAmt)
    {
        assetCount = uint8(bound(assetCount, 2, MAX_ASSET_COUNT));
        TestMarket market = _marketByAssetCount[assetCount];
        fromIdx = uint8(bound(fromIdx, 0, assetCount - 1));
        toIdx = uint8(bound(toIdx, 0, assetCount - 1));
        toAmt = bound(toIdx, 0, clampBuyAmount(toAmt, market.reserve(toIdx)));
        return market.buy(fromIdx, toIdx, toAmt);
    }

    function sellMarket(uint8 assetCount, uint8 fromIdx, uint8 toIdx, uint256 fromAmt)
        external returns (uint256 toAmt)
    {
        assetCount = uint8(bound(assetCount, 2, MAX_ASSET_COUNT));
        TestMarket market = _marketByAssetCount[assetCount];
        fromIdx = uint8(bound(fromIdx, 0, assetCount - 1));
        toIdx = uint8(bound(toIdx, 0, assetCount - 1));
        fromAmt = bound(toIdx, 0, clampSellAmount(fromAmt, market.reserve(fromIdx)));
        return market.sell(fromIdx, toIdx, fromAmt);
    }

    function marketCount() external view returns (uint8) {
        return uint8(_markets.length);
    }

    function getAllMarkets() external view returns (TestMarket[] memory markets) {
        markets = _markets;
    }
}

contract MarketsInvariantTest is Test {
    MultiMarket markets;
   
    function setUp() external {
        markets = new MultiMarket(5);
        targetContract(address(markets));
    }

    function invariant_k() external {
        TestMarket[] memory markets_ = markets.getAllMarkets();
        for (uint8 i; i < markets_.length; ++i) {
            _assertK(markets_[i]);
        }
    }

    function _assertK(TestMarket market) private {
        uint256 initialK = market.INITIAL_K();
        uint256 k = market.k();
        assertApproxEqRel(k, initialK, 1e14, 'k');
        if (k < initialK) {
            assertLe(initialK - k, 1, "k' >= k");
        }
    }
} 