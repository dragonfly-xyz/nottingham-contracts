// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { Game, IPlayer } from '~/game/Game.sol';

// Player bot that keeps trying to buy a single good.
contract SimpleBuyer is IPlayer {
    uint8 immutable PLAYER_IDX;
    uint8 immutable TARGET_ASSET;
    uint8 immutable ASSET_COUNT;

    constructor(uint8 playerIdx, uint8  playerCount)  {
        PLAYER_IDX = playerIdx;
        ASSET_COUNT = playerCount;
        TARGET_ASSET = (playerIdx % (ASSET_COUNT - 1)) + 1;
    }

    function turn(uint8 /* builderIdx */) external {
        Game game = Game(msg.sender);
        // Convert all assets to target asset.
        for (uint8 fromAsset; fromAsset < ASSET_COUNT; ++fromAsset) {
            if (fromAsset == TARGET_ASSET) continue;
            game.sell(fromAsset, TARGET_ASSET, game.balanceOf(PLAYER_IDX, fromAsset));
        }
    }

    function buildBlock() external pure returns (uint256 goldBid) {
        return 0;
    }
}
