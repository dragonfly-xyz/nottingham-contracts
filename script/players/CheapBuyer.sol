// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import './BasePlayer.sol';

// Player that buys whatever good we can get the most of each round.
contract CheapBuyer is BasePlayer {

    constructor(IGame game, uint8 playerIdx, uint8 playerCount, uint8 assetCount)
            BasePlayer(game, playerIdx, playerCount, assetCount) {}

    function createBundle(uint8 /* builderIdx */)
        external override returns (PlayerBundle memory bundle)
    {
        bundle.swaps = new SwapSell[](ASSET_COUNT);
        uint8 wantAssetIdx = _findMaxBuyableGood();
        for (uint8 i; i < GOODS_COUNT; ++i) {
            uint8 assetIdx = FIRST_GOOD_IDX + i;
            if (assetIdx != wantAssetIdx) {
                bundle.swaps[i] = SwapSell({
                    fromAssetIdx: assetIdx,
                    toAssetIdx: wantAssetIdx,
                    fromAmount: GAME.balanceOf(PLAYER_IDX, assetIdx)
                });
            }
        }
    }

    // Find the good we can buy the most of with all our other tokens.
    function _findMaxBuyableGood()
        private view returns (uint8 maxToAssetIdx)
    {
        uint256 maxToAmount = 0;
        maxToAssetIdx = FIRST_GOOD_IDX;
        for (uint8 i; i < GOODS_COUNT; ++i) {
            uint8 toAssetIdx = FIRST_GOOD_IDX + i;
            uint256 toAmount;
            for (uint8 j; j < GOODS_COUNT; ++j) {
                uint8 fromAssetIdx = FIRST_GOOD_IDX + j;
                if (fromAssetIdx == toAssetIdx) continue;
                toAmount += GAME.quoteSell(
                    fromAssetIdx,
                    toAssetIdx,
                    GAME.balanceOf(PLAYER_IDX, fromAssetIdx)
                );
            }
            if (toAmount >= maxToAmount) {
                maxToAmount = toAmount;
                maxToAssetIdx = toAssetIdx;
            }
        }
    }
}
