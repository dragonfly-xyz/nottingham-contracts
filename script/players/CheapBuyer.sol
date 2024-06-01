// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import '~/game/IGame.sol';
import './Passive.sol';

// Player that buys the cheapest good each round.
contract CheapBuyer is Passive {
    uint8 immutable PLAYER_IDX;

    constructor(uint8 playerIdx, uint8 /* playerCount */)  {
        PLAYER_IDX = playerIdx;
    }

    function createBundle(uint8 /* builderIdx */)
        external override returns (PlayerBundle memory bundle)
    {
        IGame game = IGame(msg.sender);
        uint8 assetCount = game.assetCount();
        // Convert half of gold to cheapest good.
        bundle.swaps = new SwapSell[](1);
        SwapSell memory swap = bundle.swaps[0];
        swap.fromAssetIdx = GOLD_IDX;
        swap.fromAmount = game.balanceOf(PLAYER_IDX, GOLD_IDX) / 2;
        swap.toAssetIdx = GOLD_IDX + 1;
        uint256 maxToAmount = 0;
        for (uint8 toAssetIdx = GOLD_IDX + 1; toAssetIdx < assetCount; ++toAssetIdx) {
            uint256 toAmount = game.quoteSell(GOLD_IDX, toAssetIdx, swap.fromAmount);
            if (toAmount >= maxToAmount) {
                maxToAmount = toAmount;
                swap.toAssetIdx = toAssetIdx;
            }
        }
    }
}
