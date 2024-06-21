// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import './BasePlayer.sol';

// Player that keeps trying to buy whichever good it has the most of.
contract GreedyBuyer is BasePlayer {

    constructor(IGame game, uint8 playerIdx, uint8 playerCount, uint8 assetCount)
            BasePlayer(game, playerIdx, playerCount, assetCount) {}

    function createBundle(uint8 /* builderIdx */)
        public virtual override returns (PlayerBundle memory bundle)
    {
        uint8 wantAssetIdx = _getMaxGood();
        bundle.swaps = new SwapSell[](MAX_SWAPS_PER_BUNDLE);
        // Convert every other asset to the target asset.
        for (uint8 assetIdx; assetIdx < ASSET_COUNT; ++assetIdx) {
            if (assetIdx != wantAssetIdx && assetIdx != GOLD_IDX) {
                uint256 bal = GAME.balanceOf(PLAYER_IDX, assetIdx);
                bundle.swaps[assetIdx] = SwapSell({
                    fromAssetIdx: assetIdx,
                    toAssetIdx: wantAssetIdx,
                    fromAmount: bal
                });
            }
        }
    }
}
