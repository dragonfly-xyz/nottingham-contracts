// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import './BasePlayer.sol';

// Player that keeps trying to buy whichever good it has the most of.
contract GreedyBuyer is BasePlayer {

    constructor(uint8 playerIdx, uint8 playerCount, uint8 assetCount)
            BasePlayer(playerIdx, playerCount, assetCount) {}

    function createBundle(uint8 /* builderIdx */)
        external override returns (PlayerBundle memory bundle)
    {
        IGame game = IGame(msg.sender);
        uint8 wantAssetIdx = _getMaxGood();
        bundle.swaps = new SwapSell[](ASSET_COUNT);
        // Convert every other good to the target asset.
        for (uint8 assetIdx = GOLD_IDX + 1; assetIdx < bundle.swaps.length; ++assetIdx) {
            if (assetIdx == wantAssetIdx) {
                continue;
            }
            bundle.swaps[assetIdx] = SwapSell({
                fromAssetIdx: assetIdx,
                toAssetIdx: wantAssetIdx,
                fromAmount: game.balanceOf(PLAYER_IDX, assetIdx)
            });
        }
    }
}
