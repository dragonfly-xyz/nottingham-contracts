// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import './IPlayer.sol';
import './Constants.sol';
import './GameUtils.sol';

/// @notice Game interface made up of player-callable functions.
interface IGame {
    /// @notice How many players are in this game.
    function playerCount() external view returns (uint8);
    /// @notice The last winning bid for the previous round. Will be 0 if there
    ///      was no builder.
    function lastWinningBid() external view returns (uint256);
    /// @notice Balance of a player's asset (goods or gold).
    function balanceOf(uint8 playerIdx, uint8 assetIdx)
        external view returns (uint256 balance);
    /// @notice Return the player index that matches the win condition.
    ///         Returns `INVALID_PLAYER_IDX` if no player has met the win condition.
    function findWinner() external view returns (uint8 winnerIdx);
    /// @notice Get the respective scores of each player.
    /// @dev The score is the maximum balance of each goods (non-gold) token of a player.
    function scorePlayers() external view returns (uint256[] memory scores);
    /// @notice Get the current round index.
    /// @dev Always <= MAX_ROUNDS.
    function round() external view returns (uint16 round_);
    /// @notice Get the number of kinds of assets (tokens) in the market. Goods + gold.
    /// @dev This is always equal to `playerCount` and can never go below `MIN_PLAYERS` (2).
    function assetCount() external view returns (uint8);
    /// @notice Whether a winner has been declared or the maximum number
    ///         of rounds have been played.
    function isGameOver() external view returns (bool);
    /// @notice Compute how much `toAssetIdx` asset you would get if you sold
    ///         `fromAmount` of `fromAssetIdx` asset.
    /// @dev Can revert if the swap depletes nearly all liquidity.
    function quoteSell(uint8 fromAssetIdx, uint8 toAssetIdx, uint256 fromAmount)
        external view returns (uint256 toAmount);
    /// @notice Compute how much `fromAssetIdx` asset you would sell if you bought
    ///         `tomAmount` of `toAssetIdx` asset.
    /// @dev Can revert if the swap depletes nearly all liquidity.
    function quoteBuy(uint8 fromAssetIdx, uint8 toAssetIdx, uint256 toAmount)
        external view returns (uint256 fromAmount);
    /// @notice Returns the supply of each asset pool in the market.
    function marketState() external view returns (uint256[] memory reserves);

    // BUILDER ONLY FUNCTIONS /////////////////////////////////////////////////
    // These functions can only be called during a player's buildBlock().

    /// @notice As a builder, directly sell `fromAmount` of `fromAssetIdx`
    ///         asset for `toAssetIdx` and return how much of `toAssetIdx`
    ///         was bought.
    /// @dev Can revert if the swap depletes nearly all liquidity.
    ///      Can only be called by the current block builder.
    ///      Other players must perform swaps using bundles.
    function sell(uint8 fromAssetIdx, uint8 toAssetIdx, uint256 fromAmount)
        external returns (uint256 toAmount);
    /// @notice As a builder, directly buy `toAmount` of `toAssetIdx`
    ///         asset for `fromAssetIdx` and return how much of `fromAssetIdx`
    ///         was sold.
    /// @dev Can revert if the swap depletes nearly all liquidity.
    ///      Can only be called by the current block builder.
    ///      Other players must perform swaps using bundles.
    function buy(uint8 fromAssetIdx, uint8 toAssetIdx, uint256 toAmount)
        external returns (uint256 fromAmount);
    /// @notice As a builder, settle another player's swap bundle.
    /// @dev This will perform all the swaps in the bundle in order.
    ///      If any of the swaps in the bundle revert, the entire bundle
    ///      reverts, but the block will still be valid. The builder cannot
    ///      modify another player's bundle without causing their
    ///      block to be discarded.
    function settleBundle(uint8 playerIdx, PlayerBundle memory bundle)
        external returns (bool success);

    // END OF BUILDER ONLY FUNCTIONS //////////////////////////////////////////
}
