// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

uint256 constant MIN_LIQUIDITY_PER_RESERVE = 1e4;
uint256 constant MAX_LIQUIDITY_PER_RESERVE = 1e32;

// A multidimensional virtual AMM for 18-decimal asset tokens.
abstract contract AssetMarket {

    error MinLiquidityError();
    error MaxLiquidityError();
    error InsufficientLiquidityError();
    error InvalidAssetError();
    error MinKError();
    error PrecisionError();

    uint8 internal immutable ASSET_COUNT;
    mapping (uint8 => uint256) private _reserves;

    constructor(uint8 assetCount) {
        assert(assetCount <= type(uint8).max);
        ASSET_COUNT = uint8(assetCount);
    }

    function _init(uint256[] memory initialReserveAmounts) internal {
        assert(initialReserveAmounts.length == ASSET_COUNT);
        uint256[] memory reserves;
        // uint256 and 18-decimal tokens have identical bit representations so this is OK.
        assembly ("memory-safe") { reserves := initialReserveAmounts }
        for (uint256 i; i < reserves.length; ++i) {
            if (reserves[i] < MIN_LIQUIDITY_PER_RESERVE) revert MinLiquidityError();
            if (reserves[i] > MAX_LIQUIDITY_PER_RESERVE) revert MaxLiquidityError();
        }
        _storeReserves(reserves);
    }

    function _buy(uint8 fromIdx, uint8 toIdx, uint256 toAmt)
        internal returns (uint256 fromAmt)
    {
        if (fromIdx >= ASSET_COUNT || toIdx >= ASSET_COUNT) revert InvalidAssetError();
        if (fromIdx == toIdx) return toAmt;
        uint256[] memory reserves = _loadReserves();
        fromAmt = _quoteBuyFromReserves(reserves[fromIdx], reserves[toIdx], toAmt);
        reserves[fromIdx] = reserves[fromIdx] + fromAmt;
        reserves[toIdx] = reserves[toIdx] - toAmt;
        _reserves[fromIdx] = reserves[fromIdx];
        _reserves[toIdx] = reserves[toIdx];
    }

    function _sell(uint8 fromIdx, uint8 toIdx, uint256 fromAmt)
        internal returns (uint256 toAmt)
    {
        if (fromIdx >= ASSET_COUNT || toIdx >= ASSET_COUNT) revert InvalidAssetError();
        if (fromIdx == toIdx) return fromAmt;
        uint256[] memory reserves = _loadReserves();
        toAmt = _quoteSellFromReserves(reserves[fromIdx], reserves[toIdx], fromAmt);
        reserves[fromIdx] = reserves[fromIdx] + fromAmt;
        reserves[toIdx] = reserves[toIdx] - toAmt;
        _reserves[fromIdx] = reserves[fromIdx];
        _reserves[toIdx] = reserves[toIdx];
    }

    function _leak(uint8 idx, uint256 amt) internal {
        if (idx >= ASSET_COUNT) revert InvalidAssetError();
        uint256 toReserve = _getReserve(idx);
        if (amt >= toReserve) revert InsufficientLiquidityError();
        if (toReserve - amt < MIN_LIQUIDITY_PER_RESERVE) revert MinLiquidityError();
        _reserves[idx] = toReserve - amt;
    }

    function _getReserve(uint8 idx) internal view returns (uint256 weiReserve) {
        return _reserves[idx];
    }

    function _getRate(uint8 fromIdx, uint8 toIdx) internal view returns (uint256 toRate) {
        if (fromIdx == toIdx) return 1e18;
        return _reserves[toIdx] * 1e18 / _reserves[fromIdx];
    }

    function _quoteBuy(uint8 fromIdx, uint8 toIdx, uint256 toAmt)
        internal view returns (uint256 fromAmt)
    {
        if (fromIdx >= ASSET_COUNT || toIdx >= ASSET_COUNT) revert InvalidAssetError();
        if (fromIdx == toIdx) return toAmt;
        uint256[] memory reserves = _loadReserves();
        fromAmt = _quoteBuyFromReserves(reserves[fromIdx], reserves[toIdx], toAmt);
    }

    function _quoteSell(uint8 fromIdx, uint8 toIdx, uint256 fromAmt)
        internal view returns (uint256 toAmt)
    {
        if (fromIdx >= ASSET_COUNT || toIdx >= ASSET_COUNT) revert InvalidAssetError();
        if (fromIdx == toIdx) return fromAmt;
        uint256[] memory reserves = _loadReserves();
        toAmt = _quoteSellFromReserves(reserves[fromIdx], reserves[toIdx], fromAmt);
    }

    function _quoteBuyFromReserves(uint256 fromReserve, uint256 toReserve, uint256 toAmt)
        private pure returns (uint256 fromAmt)
    {
        if (toAmt == 0) return 0;
        if (toAmt >= toReserve) revert InsufficientLiquidityError();
        if (toReserve - toAmt < MIN_LIQUIDITY_PER_RESERVE) revert MinLiquidityError();
        uint256 d = toReserve - toAmt;
        fromAmt = (toAmt * fromReserve + d - 1) / d;
        if (fromReserve + fromAmt > MAX_LIQUIDITY_PER_RESERVE) revert MaxLiquidityError();
        if (fromAmt == 0 || fromAmt < toAmt * fromReserve / toReserve) revert PrecisionError();
    }

    function _quoteSellFromReserves(uint256 fromReserve, uint256 toReserve, uint256 fromAmt)
        private pure returns (uint256 toAmt)
    {
        if (fromAmt == 0) return 0;
        if (fromReserve + fromAmt > MAX_LIQUIDITY_PER_RESERVE) revert MaxLiquidityError();
        toAmt = (fromAmt * toReserve) / (fromReserve + fromAmt);
        if (toReserve - toAmt < MIN_LIQUIDITY_PER_RESERVE) revert MinLiquidityError();
    }

    function _storeReserves(uint256[] memory reserves) internal {
        for (uint8 i; i < reserves.length; ++i) {
            _reserves[i] = reserves[i];
        }
    }

    function _loadReserves() internal view returns (uint256[] memory reserves) {
        reserves = new uint256[](ASSET_COUNT);
        for (uint8 i; i < ASSET_COUNT; ++i) {
            reserves[i] = _reserves[i];
        }
    }
}