// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import './BasePlayer.sol';

// Player that keeps trying to buy a single good.
contract SimpleBuyer is BasePlayer {
    uint8 immutable WANT_ASSET_IDX;

    constructor(IGame game, uint8 playerIdx, uint8 playerCount, uint8 assetCount)
        BasePlayer(game, playerIdx, playerCount, assetCount)
    {
        WANT_ASSET_IDX = (PLAYER_IDX % GOODS_COUNT) + FIRST_GOOD_IDX;
    }

    function createBundle(uint8 /* builderIdx */)
        external override returns (PlayerBundle memory bundle)
    {
        bundle.swaps = new SwapSell[](ASSET_COUNT);
        // Convert all non-gold assets to target asset.
        for (uint8 i; i < GOODS_COUNT; ++i) {
            uint8 assetIdx = FIRST_GOOD_IDX + i;
            if (assetIdx == WANT_ASSET_IDX) continue;
            bundle.swaps[i] = SwapSell({
                fromAssetIdx: assetIdx,
                toAssetIdx: WANT_ASSET_IDX,
                fromAmount: GAME.balanceOf(PLAYER_IDX, assetIdx)
            });
        }
    }
}
