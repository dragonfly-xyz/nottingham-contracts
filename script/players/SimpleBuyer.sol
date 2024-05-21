// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { Game, IPlayer, PlayerBundle, SwapSell, GOLD_IDX } from '~/game/Game.sol';
import { Noop } from './Noop.sol';

// Player that keeps trying to buy a single good.
contract SimpleBuyer is Noop {
    uint8 immutable PLAYER_IDX;
    uint8 immutable TARGET_ASSET;

    constructor(uint8 playerIdx, uint8 playerCount)  {
        PLAYER_IDX = playerIdx;
        TARGET_ASSET = (playerIdx % (playerCount - 1)) + 1;
    }

    function createBundle(uint8 /* builderIdx */)
        external override returns (PlayerBundle memory bundle)
    {
        Game game = Game(msg.sender);
        uint8 assetCount = game.assetCount();
        bundle.swaps = new SwapSell[](assetCount - 1);
        // Convert all non-gold assets to target asset.
        for (uint8 i = 1; i < bundle.swaps.length; ++i) {
            uint8 fromAsset = i >= TARGET_ASSET ? i + 1 : i;
            bundle.swaps[i - 1] = SwapSell({
                fromAssetIdx: fromAsset,
                toAssetIdx: TARGET_ASSET,
                fromAmount: game.balanceOf(PLAYER_IDX, fromAsset)
            });
        }
        // Convert half of gold into target asset.
        bundle.swaps[bundle.swaps.length - 1] = SwapSell({
            fromAssetIdx: GOLD_IDX,
            toAssetIdx: TARGET_ASSET,
            fromAmount: game.balanceOf(PLAYER_IDX, GOLD_IDX) / 2
        });
    }
}