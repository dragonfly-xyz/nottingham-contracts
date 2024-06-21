// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import '~/game/IGame.sol';

// Base class for example players.
// Creates empty bundles and settles all players in order and
// bids all our gold.
contract BasePlayer is IPlayer {
    // The game instance.
    IGame internal immutable GAME;
    // Our player index.
    uint8 internal immutable PLAYER_IDX;
    // How many players are in the game.
    uint8 internal immutable PLAYER_COUNT;
    // How many assets (including gold) are in the game.
    uint8 internal immutable ASSET_COUNT;
    // How many goods (assets that aren't gold) are in the game.
    uint8 internal immutable GOODS_COUNT;
    // Maximum number of swaps allowed in a single player bundle.
    uint8 internal immutable MAX_SWAPS_PER_BUNDLE;
    
    constructor(IGame game, uint8 playerIdx, uint8 playerCount, uint8 assetCount) {
        GAME = game;
        PLAYER_IDX = playerIdx;
        PLAYER_COUNT = playerCount;
        ASSET_COUNT = assetCount;
        GOODS_COUNT = ASSET_COUNT - 1;
        MAX_SWAPS_PER_BUNDLE = ASSET_COUNT * (ASSET_COUNT - 1);
    }

    function createBundle(uint8 /* builderIdx */)
        public virtual returns (PlayerBundle memory bundle)
    {}

    function buildBlock(PlayerBundle[] calldata bundles)
        public virtual returns (uint256 goldBid)
    {
        // Settle all player bundles in player order.
        for (uint8 playerIdx; playerIdx < bundles.length; ++playerIdx) {
            GAME.settleBundle(playerIdx, bundles[playerIdx]);
        }
        // Bid all our gold.
        return GAME.balanceOf(PLAYER_IDX, GOLD_IDX);
    }

    // Find the good (non-gold asset) we have the highest balance of.
    function _getMaxGood() internal view returns (uint8 maxAssetIdx) {
        uint256 maxBalance;
        for (uint8 i; i < GOODS_COUNT; ++i) {
            uint8 assetIdx = FIRST_GOOD_IDX + i;
            uint256 bal = GAME.balanceOf(PLAYER_IDX, assetIdx);
            if (maxBalance <= bal) {
                maxAssetIdx = assetIdx;
                maxBalance = bal;
            }
        }
    }

    // Find the good (non-gold asset) we have the lowest balance of.
    function _getMinGood() internal view returns (uint8 minAssetIdx) {
        minAssetIdx = FIRST_GOOD_IDX;
        uint256 minBalance = GAME.balanceOf(PLAYER_IDX, FIRST_GOOD_IDX);
        for (uint8 i = 1; i < GOODS_COUNT; ++i) {
            uint8 assetIdx = FIRST_GOOD_IDX + i;
            uint256 bal = GAME.balanceOf(PLAYER_IDX, assetIdx);
            if (minBalance >= bal) {
                minAssetIdx = assetIdx;
                minBalance = bal;
            }
        }
    }
}