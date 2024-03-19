// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { Game, IPlayer, PlayerBundle, SwapSell } from '~/game/Game.sol';

// Player bot that keeps trying to buy a single good.
contract SimpleBuyer is IPlayer {
    uint8 immutable PLAYER_IDX;
    uint8 immutable TARGET_ASSET;

    constructor(uint8 playerIdx, uint8 playerCount)  {
        PLAYER_IDX = playerIdx;
        TARGET_ASSET = (playerIdx % (playerCount - 1)) + 1;
    }

    function createBundle(uint8 /* builderIdx */)
        external returns (PlayerBundle memory bundle)
    {
        Game game = Game(msg.sender);
        // Convert all assets to target asset.
        uint8 assetCount = game.assetCount();
        bundle.swaps = new SwapSell[](assetCount - 1);
        for (uint8 i; i < bundle.swaps.length; ++i) {
            uint8 fromAsset = i == TARGET_ASSET
                ? (i + 1) % assetCount
                : i;
            bundle.swaps[i] = SwapSell({
                fromAssetIdx: fromAsset,
                toAssetIdx: TARGET_ASSET,
                fromAmount: game.balanceOf(PLAYER_IDX, fromAsset),
                minToAmount: type(uint256).max
            });
        }
    }

    function buildBlock(PlayerBundle[] memory bundles)
        external pure returns (uint256 goldBid)
    {
        return 0;
    }
}
