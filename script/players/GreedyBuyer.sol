// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import '~/game/IGame.sol';
import './Passive.sol';

// Player that keeps trying to buy whichever good it has the most of.
contract GreedyBuyer is Passive {
    uint8 immutable PLAYER_IDX;

    constructor(uint8 playerIdx, uint8 /* playerCount */)  {
        PLAYER_IDX = playerIdx;
    }

    function createBundle(uint8 /* builderIdx */)
        external override returns (PlayerBundle memory bundle)
    {
        IGame game = IGame(msg.sender);
        uint8 assetCount = game.assetCount();
        uint8 targetAsset = _getGoodWithMaxBalance(game);
        bundle.swaps = new SwapSell[](assetCount);
        // Convert everything to the target asset.
        for (uint8 fromAsset = GOLD_IDX; fromAsset < bundle.swaps.length; ++fromAsset) {
            if (fromAsset == targetAsset) {
                continue;
            }
            bundle.swaps[fromAsset] = SwapSell({
                fromAssetIdx: fromAsset,
                toAssetIdx: targetAsset,
                fromAmount: game.balanceOf(PLAYER_IDX, fromAsset)
            });
        }
    }

    function _getGoodWithMaxBalance(IGame game)
        private view returns (uint8 maxAssetIdx)
    {
        uint8 assetCount = game.assetCount();
        // Find the good we have the most of.
        uint256 maxAssetBal = GOLD_IDX + 1;
        for (uint8 assetIdx = GOLD_IDX + 1; assetIdx < assetCount; ++assetIdx) {
            uint256 bal = game.balanceOf(PLAYER_IDX, assetIdx);
            if (bal >= maxAssetBal) {
                maxAssetBal = bal;
                maxAssetIdx = assetIdx;
            }
        }
    }
}
