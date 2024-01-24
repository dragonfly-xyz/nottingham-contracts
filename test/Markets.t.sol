pragma solidity ^0.8;

import { Test } from "forge-std/Test.sol";
import { AssetMarket, MIN_LIQUIDITY_PER_RESERVE } from "~/Markets.sol";
import { LibTestUtils as T } from "./LibTestUtils.sol";
import {
    calcK,
    clampBuyAmount,
    clampSellAmount,
    TestMarket,
    createTestMarket
} from "./MarketTestUtils.sol";

contract MarketTest is Test {
    function test_creationFailsIfBelowMinLiquidity() external {
        vm.expectRevert(AssetMarket.MinLiquidityError.selector);
        new TestMarket(T.toDynArray([uint256(1e18), uint256(MIN_LIQUIDITY_PER_RESERVE-1)]));
    }
    
    function test_canSellOne() external {
        TestMarket m = createTestMarket(2);
        uint256 buyAmount = m.sell(0, 1, 1);
        assertEq(buyAmount, 0); // Rounds to zero.
        _assertK(m);
    }

    function test_canSellEntireReserve() external {
        TestMarket m = createTestMarket(2);
        uint256[] memory reserves = m.reserves();
        uint256 sellAmount = reserves[0];
        uint256 maxBuyAmount = sellAmount * reserves[1] / reserves[0];
        uint256 buyAmount = m.sell(0, 1, sellAmount);
        assertLe(buyAmount, maxBuyAmount);
        assertEq(m.reserve(0), reserves[0] * 2);
        assertEq(m.reserve(1), reserves[1] - buyAmount);
        _assertK(m);
    }

    function test_canSellMoreThanEntireReserve() external {
        TestMarket m = createTestMarket(2);
        uint256[] memory reserves = m.reserves();
        uint256 sellAmount = reserves[0];
        uint256 maxBuyAmount = sellAmount * reserves[1] / reserves[0] + 1;
        uint256 buyAmount = m.sell(0, 1, sellAmount);
        assertLe(buyAmount, maxBuyAmount);
        assertEq(m.reserve(0), reserves[0] * 2);
        assertEq(m.reserve(1), reserves[1] - buyAmount);
        _assertK(m);
    }

    function test_cannotBuyEntireReserve() external {
        TestMarket m = createTestMarket(2);
        uint256 toAmt = m.reserve(1);
        vm.expectRevert(AssetMarket.InsufficientLiquidityError.selector);
        m.buy(0, 1, toAmt);
    }

    function test_cannotBuyMoreThanMinLiquidityRemainingOfReserve() external {
        TestMarket m = createTestMarket(2);
        uint256 toAmt = m.reserve(1) - MIN_LIQUIDITY_PER_RESERVE + 1;
        vm.expectRevert(AssetMarket.MinLiquidityError.selector);
        m.buy(0, 1, toAmt);
    }

    function test_canBuyLessThanEntireReserve() external {
        TestMarket m = createTestMarket(2);
        uint256 sellAmount = m.buy(0, 1, 1e16 - MIN_LIQUIDITY_PER_RESERVE);
        assertGt(sellAmount, 1e16);
        _assertK(m);
    }
    function test_canBuyPct(uint16 bps) external {
        TestMarket m = createTestMarket(5);
        uint8 assetCount = m.ASSET_COUNT();
        for (uint256 i; i < assetCount; ++i) {
            uint256[] memory reserves = m.reserves();
            uint8 fromIdx = uint8((i + 0) % assetCount);
            uint8 toIdx = uint8((i + 1) % assetCount);
            uint256 buyAmount = bound(bps, 0, 1e4) * reserves[toIdx] / 1e4;
            try m.buy(fromIdx, toIdx, buyAmount) returns (uint256 sellAmount) {
                assertEq(m.reserve(fromIdx), reserves[fromIdx] + sellAmount, 'fromReserve');
                assertEq(m.reserve(toIdx), reserves[toIdx] - buyAmount, 'toReserve');
                _assertK(m);
            } catch {}
        }
    }

    function test_canSellPct(uint16 bps) external {
        TestMarket m = createTestMarket(5);
        uint8 assetCount = m.ASSET_COUNT();
        for (uint256 i; i < assetCount; ++i) {
            uint256[] memory reserves = m.reserves();
            uint8 fromIdx = uint8((i + 0) % assetCount);
            uint8 toIdx = uint8((i + 1) % assetCount);
            uint256 sellAmount = bound(bps, 0, 1000e4) * reserves[fromIdx] / 1e4;
            try m.sell(fromIdx, toIdx, sellAmount) returns (uint256 buyAmount) {
                assertEq(m.reserve(fromIdx), reserves[fromIdx] + sellAmount, 'fromReserve');
                assertEq(m.reserve(toIdx), reserves[toIdx] - buyAmount, 'toReserve');
                _assertK(m);
            } catch {}
        }
    }

    function test_canBuyThenSellSymmetricallyAcrossPools(uint16 bps) external {
        TestMarket m = createTestMarket(5);
        uint8 assetCount = m.ASSET_COUNT();
        for (uint256 i; i < assetCount; ++i) {
            uint256[] memory reserves = m.reserves();
            uint8 fromIdx = uint8((i + 0) % assetCount);
            uint8 toIdx = uint8((i + 1) % assetCount);
            uint256 buyAmount = bound(bps, 0, 1000e4) * reserves[toIdx] / 1e4;
            uint256 sellAmount;
            try m.buy(fromIdx, toIdx, buyAmount) returns (uint256 $) { sellAmount = $; }
            catch { continue; }
            assertEq(m.reserve(fromIdx), reserves[fromIdx] + sellAmount, 'fromReserve (after buy)');
            assertEq(m.reserve(toIdx), reserves[toIdx] - buyAmount, 'toReserve (after buy)');
            _assertK(m);
            try m.sell(toIdx, fromIdx, buyAmount) {}
            catch { continue; }
            assertApproxEqAbs(m.reserve(fromIdx), reserves[fromIdx], 1, 'fromReserve (after sell)');
            assertApproxEqAbs(m.reserve(toIdx), reserves[toIdx], 1, 'toReserve (after sell)');
            _assertK(m);
        }
    }

    function test_canSellThenBuySymmetricallyAcrossPools(uint16 bps) external {
        TestMarket m = createTestMarket(5);
        uint8 assetCount = m.ASSET_COUNT();
        for (uint256 i; i < assetCount; ++i) {
            uint256[] memory reserves = m.reserves();
            uint8 fromIdx = uint8((i + 0) % assetCount);
            uint8 toIdx = uint8((i + 1) % assetCount);
            uint256 sellAmount = bound(bps, 0, 1000e4) * reserves[fromIdx] / 1e4;
            uint256 buyAmount;
            try m.sell(fromIdx, toIdx, sellAmount) returns (uint256 $) { buyAmount = $; }
            catch { continue; }
            assertEq(m.reserve(fromIdx), reserves[fromIdx] + sellAmount, 'fromReserve (after sell)');
            assertEq(m.reserve(toIdx), reserves[toIdx] - buyAmount, 'toReserve (after sell)');
            _assertK(m);
            try m.buy(toIdx, fromIdx, sellAmount) {}
            catch { continue; }
            assertApproxEqRel(m.reserve(fromIdx), reserves[fromIdx], 1e14, 'fromReserve (after buy)');
            assertApproxEqRel(m.reserve(toIdx), reserves[toIdx], 1e14, 'toReserve (after buy)');
            _assertK(m);
        }
    }

    function _assertK(TestMarket market) private {
        uint256 initialK = market.INITIAL_K();
        uint256 k = market.k();
        assertApproxEqRel(k, initialK, 1e14, 'k');
        assertGe(k, initialK, "k' >= k");
    }
}