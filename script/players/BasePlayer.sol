// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import '~/game/IGame.sol';

// Base class for example players.
// Creates empty bundles and settles all players in order.
contract BasePlayer is IPlayer {
    IGame internal immutable GAME;
    uint8 internal immutable PLAYER_IDX;
    uint8 internal immutable PLAYER_COUNT;
    uint8 internal immutable ASSET_COUNT;
    uint8 internal immutable GOODS_COUNT;
    
    constructor(uint8 playerIdx, uint8 playerCount, uint8 assetCount) {
        GAME = IGame(msg.sender);
        PLAYER_IDX = playerIdx;
        PLAYER_COUNT = playerCount;
        ASSET_COUNT = assetCount;
        GOODS_COUNT = ASSET_COUNT - 1;
    }

    function createBundle(uint8 /* builderIdx */)
        external virtual returns (PlayerBundle memory bundle)
    {}

    function buildBlock(PlayerBundle[] calldata bundles)
        external virtual returns (uint256 goldBid)
    {
        // Settle all player bundles in player order.
        for (uint8 playerIdx; playerIdx < bundles.length; ++playerIdx) {
            GAME.settleBundle(playerIdx, bundles[playerIdx]);
        }
        // Bid the minimum.
        return 1;
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