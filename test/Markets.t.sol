pragma solidity ^0.8;

import { Test } from "forge-std/Test.sol";
import { MIN_LIQUIDITY_PER_RESERVE } from "~/Markets.sol";
import {
    calcK,
    clampBuyAmount,
    clampSellAmount,
    TestMarket,
    createTestMarket
} from "./MarketTestUtils.sol";

contract MarketTest is Test {
    function test_canBuyPct(uint16 bps) external {
        TestMarket market = createTestMarket(5);
        uint8 assetCount = market.ASSET_COUNT();
        for (uint256 i; i < assetCount; ++i) {
            uint8 fromIdx = uint8((i + 0) % assetCount);
            uint8 toIdx = uint8((i + 1) % assetCount);
            try market.buy(
                fromIdx,
                toIdx,
                bound(bps, 0, 1e4) * market.reserve(toIdx) / 1e4
            ) {
                assertApproxEqRel(market.k(), market.INITIAL_K(), 1e4, 'k');
            } catch {}
        }
    }

    function test_canSellPct(uint16 bps) external {
        TestMarket market = createTestMarket(5);
        uint8 assetCount = market.ASSET_COUNT();
        for (uint256 i; i < assetCount; ++i) {
            uint8 fromIdx = uint8((i + 0) % assetCount);
            uint8 toIdx = uint8((i + 1) % assetCount);
            try market.sell(
                fromIdx,
                toIdx,
                bound(bps, 0, 1000e4) * market.reserve(fromIdx) / 1e4
            ) {
                assertApproxEqRel(market.k(), market.INITIAL_K(), 1e4, 'k');
            } catch {}
        }
    }
}