// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { Game, IPlayer, PlayerBundle, SwapSell, GOLD_IDX } from '~/game/Game.sol';
import { Passive } from './Passive.sol';

// Player that spends an equal amount of gold on each good.
contract EvenBuyer is Passive {
    uint8 immutable PLAYER_IDX;

    constructor(uint8 playerIdx, uint8 /* playerCount */)  {
        PLAYER_IDX = playerIdx;
    }

    function createBundle(uint8 /* builderIdx */)
        external override returns (PlayerBundle memory bundle)
    {
        Game game = Game(msg.sender);
        uint8 assetCount = game.assetCount();
        // Sell half of gold equally across all goods.
        uint256 fromAmount =
            game.balanceOf(PLAYER_IDX, GOLD_IDX) / 2 / (assetCount - 1);
        bundle.swaps = new SwapSell[](assetCount - 1);
        for (uint8 toAssetIdx = GOLD_IDX + 1; toAssetIdx < assetCount; ++toAssetIdx) {
            bundle.swaps[toAssetIdx - 1] = SwapSell({
                fromAssetIdx: GOLD_IDX,
                toAssetIdx: toAssetIdx,
                fromAmount: fromAmount
            });
        }
    }
}
