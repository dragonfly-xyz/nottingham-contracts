// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { Game, IPlayer, PlayerBundle, SwapSell, GOLD_IDX } from '~/game/Game.sol';
import { Noop } from './Noop.sol';

// Player that tries to buy whichever good it has the most of
// AND tries to perform its swaps before everyone else.
contract FrontRunner is Noop {
    uint8 immutable PLAYER_IDX;

    constructor(uint8 playerIdx, uint8 /* playerCount */)  {
        PLAYER_IDX = playerIdx;
    }

    function createBundle(uint8 /* builderIdx */)
        external override returns (PlayerBundle memory bundle)
    {
        Game game = Game(msg.sender);
        uint8 assetCount = game.assetCount();
        uint8 targetAsset = _getGoodWithMaxBalance(game);
        bundle.swaps = new SwapSell[](assetCount);
        // Convert everything to the target asset.
        for (uint8 fromAsset = GOLD_IDX; fromAsset < assetCount; ++fromAsset) {
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

    function buildBlock(PlayerBundle[] memory bundles)
        external override returns (uint256 goldBid)
    {
        Game game = Game(msg.sender);
        // Execute our swaps first. Cut the gold amount by half so we
        // have something to bid.
        // We could make calls to Game.sell() or Game.buy() directly here
        // but for simplicity we'll just edit our own bundle and settle it.
        // The game only allows us to edit our own bundles.
        bundles[PLAYER_IDX].swaps[GOLD_IDX].fromAmount =
            game.balanceOf(PLAYER_IDX, GOLD_IDX) / 2;
        game.settleBundle(PLAYER_IDX, bundles[PLAYER_IDX]);
        for (uint8 playerIdx = 0; playerIdx < bundles.length; ++playerIdx) {
            if (playerIdx == PLAYER_IDX) {
                continue;
            }
            game.settleBundle(playerIdx, bundles[playerIdx]);
        }
        // Bid all remaining gold.
        return game.balanceOf(PLAYER_IDX, GOLD_IDX);
    }

    function _getGoodWithMaxBalance(Game game)
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
