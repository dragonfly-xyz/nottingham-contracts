// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { AssetMarket } from './Markets.sol';
import { LibBytes } from './LibBytes.sol';
import { LibAddress } from './LibAddress.sol';
import { IPlayer, PlayerBundle, SwapSell } from './IPlayer.sol';
import { SafeCreate2 } from './SafeCreate2.sol';
import { IGame } from './IGame.sol';
import './Constants.sol';
import './GameUtils.sol';
import './Transient.sol';

/// @notice A friendly game of Searchers of Nottingham.
/// @dev One instance is deployed per game.
contract Game is IGame, AssetMarket {
    using LibBytes for bytes;
    using LibAddress for address;
    
    /// @dev Transient bytes32 array to remember player bundle hashes
    ///      during a block.
    TransientArray_Bytes32 internal constant t_playerBundleHash =
        TransientArray_Bytes32.wrap(1);
    /// @dev Transient bool reentrancy guard for playRound().
    TransientBool internal constant t_inRound =
        TransientBool.wrap(2);
    /// @dev Transient address indicating current builder during a block.
    TransientAddress internal constant t_currentBuilder =
        TransientAddress.wrap(3);

    /// @notice Who can call playRound().
    address public immutable gm;
    /// @notice How many players are in this game.
    uint8 public immutable playerCount;
    /// @dev How many rounds have passed.
    ///      Warning: Upper bits will be set when the game has encountered
    ///      a win state.
    uint16 internal _round;
    /// @notice Player index of the last builder.
    /// @dev    `INVALID_PLAYER_IDX` if no builder (emtpy block).
    uint8 public lastBuilder;
    /// @notice The last winning bid for the previous round. Will be 0 if there
    ///      was no builder.
    uint256 public lastWinningBid;
    /// @notice Balance of a player's asset (goods or gold).
    mapping (uint8 playerIdx => mapping (uint8 assetIdx => uint256 balance)) public
        balanceOf;
    /// @dev Map of player idxs to addresses.
    mapping (uint8 playerIdx => IPlayer player) internal  _playerByIdx;

    error GameOverError();
    error GameSetupError(string message);
    error AccessError();
    error AlreadyInRoundError();
    error DuringBlockError();
    error InsufficientBalanceError(uint8 playerIdx, uint8 assetIdx);
    error BundleNotSettledError(uint8 builderIdx, uint8 playerIdx);
    error BuildBlockFailedError(uint8 builderIdx, bytes revertData);
    error OnlySelfError();
    error TooManySwapsError();
    error BundleAlreadySettledError(uint8 playerIdx);
    error BuildPlayerBlockAndRevertSuccess(uint256 bid);
    error InsufficientBundleGasError();
    
    event CreatePlayerFailed(uint8 playerIdx);
    event RoundPlayed(uint16 round);
    event CreateBundleFailed(uint8 playerIdx, uint8 builderIdx, bytes revertData);
    event Mint(uint8 playerIdx, uint8 assetIdx, uint256 assetAmount);
    event Burn(uint8 playerIdx, uint8 assetIdx, uint256 assetAmount);
    event Transfer(uint8 fromPlayerIdx, uint8 toPlayerIdx, uint8 assetIdx, uint256 assetAmount);    
    event BlockBid(uint8 builderIdx, uint256 bid);
    event BlockBuilt(uint16 round, uint8 builderIdx, uint256 bid);
    event EmptyBlock(uint16 round);
    event BuildPlayerBlockFailed(uint8 builderIdx, bytes data);
    event Swap(uint8 playerIdx, uint8 fromAssetIdx, uint8 toAssetIdx, uint256 fromAmount, uint256 toAmount);
    event GameOver(uint16 rounds, uint8 winnerIdx); 
    event PlayerBlockGasUsage(uint8 builderIdx, uint32 gasUsed);
    event PlayerBundleGasUsage(uint8 builderIdx, uint32 gasUsed);
    event BundleSettled(uint8 playerIdx, bool success, PlayerBundle bundle);

    modifier onlyGameMaster() {
        require(msg.sender == gm, AccessError());
        _;
    }
   
    modifier onlyBuilder() {
        require(msg.sender == address(t_currentBuilder.load()), AccessError());
        _;
    }
   
    modifier onlySelf() {
        require(msg.sender == address(this), OnlySelfError());
        _;
    }
   
    /// @notice Create a new game.
    /// @dev This will also deploy all players. A failing player deployment will
    ///      not cause a revert. The game will proceed essentially as if the player
    ///     is doing nothing. Players are deployed with CREATE2 and a salt must be
    ///     mined that ensures that the last 3 bits of the deployed address matches
    ///     each player's index (the order they're passed in).
    constructor(
        address gameMaster,
        SafeCreate2 sc2,
        bytes[] memory playerCreationCodes,
        uint256[] memory deploySalts
    )
        // There will be n-player assets (incl gold) in the market to ensure
        // at least one asset will be in contention.
        AssetMarket(uint8(playerCreationCodes.length))
    {
        require(
            playerCreationCodes.length == deploySalts.length,
            GameSetupError('mismatched arrays')
        );
        gm = gameMaster;
        playerCount = uint8(playerCreationCodes.length);
        require(
            playerCount >= MIN_PLAYERS && playerCount <= MAX_PLAYERS,
            GameSetupError('# of players')
        );
        // Deploy players.
        playerCount = uint8(playerCreationCodes.length);
        {
            bytes memory initArgs = abi.encode(this, 0, playerCount, ASSET_COUNT);
            for (uint8 i; i < playerCount; ++i) {
                assembly ('memory-safe') { mstore(add(initArgs, 0x40), i) }

                IPlayer player;
                try sc2.safeCreate2{gas: MAX_CREATION_GAS}(
                    playerCreationCodes[i],
                    deploySalts[i],
                    initArgs
                ) returns (address player_) {
                    player = IPlayer(player_);
                } catch {
                    // Deployment failed.
                    // Assign to a nonzero but empty player address.
                    player = IPlayer(address(uint160((1 << 159) | i)));
                    emit CreatePlayerFailed(i);
                }
                // The lowest 3 bits of each deployed address should also hold the
                // player index.
                require(
                    getIndexFromPlayer(player) == i,
                    GameSetupError('player index')
                );
                _playerByIdx[i] = player;
            }
        }
        // Initialize the market.
        {
            uint8 assetCount_ = uint8(ASSET_COUNT);
            uint256[] memory assetReserves = new uint256[](assetCount_);
            assetReserves[GOLD_IDX] = MARKET_STARTING_GOLD_PER_PLAYER * playerCount;
            for (uint8 i = 1; i < assetCount_; ++i) {
                assetReserves[i] = MARKET_STARTING_GOODS_PER_PLAYER * playerCount;
            }
            AssetMarket._init(assetReserves);
        }
    }

    /// @inheritdoc IGame
    function findWinner() external view returns (uint8 winnerIdx) {
        IPlayer winner = _findWinner(_round);
        return winner == NULL_PLAYER ? INVALID_PLAYER_IDX : getIndexFromPlayer(winner);
    }

    /// @inheritdoc IGame
    function scorePlayers() external view returns (uint256[] memory scores) {
        scores = new uint256[](playerCount);
        for (uint8 playerIdx; playerIdx < scores.length; ++playerIdx) {
            (, scores[playerIdx]) = _getMaxNonGoldAssetForPlayer(playerIdx);
        }
    }

    /// @inheritdoc IGame
    function round() public view returns (uint16 round_) {
        return _getTrueRoundCount(_round);
    }

    /// @inheritdoc IGame
    function assetCount() external view returns (uint8) {
        return ASSET_COUNT;
    }

    /// @inheritdoc IGame
    function isGameOver() public view returns (bool) {
        // Upper bit in `_rounds` will be set if a winner is found at the
        // end of playRound() so this expression will be true either if
        // a winner is declared or if the maximum number of rounds has been
        // reached.
        return _round >= MAX_ROUNDS;
    }

    /// @inheritdoc IGame
    function quoteSell(uint8 fromAssetIdx, uint8 toAssetIdx, uint256 fromAmount)
        external view returns (uint256 toAmount)
    {
        _assertValidAsset(fromAssetIdx);
        _assertValidAsset(toAssetIdx);
        return AssetMarket._quoteSell(fromAssetIdx, toAssetIdx, fromAmount);
    }

    /// @inheritdoc IGame
    function quoteBuy(uint8 fromAssetIdx, uint8 toAssetIdx, uint256 toAmount)
        external view returns (uint256 fromAmount)
    {
        _assertValidAsset(fromAssetIdx);
        _assertValidAsset(toAssetIdx);
        return AssetMarket._quoteBuy(fromAssetIdx, toAssetIdx, toAmount);
    }

    /// @inheritdoc IGame
    function marketState() external view returns (uint256[] memory reserves) {
        reserves = new uint256[](ASSET_COUNT);
        for (uint8 assetIdx; assetIdx < ASSET_COUNT; ++assetIdx) {
            reserves[assetIdx] = AssetMarket._getReserve(assetIdx);
        }
        return reserves;
    }

    /// @notice Play a game round.
    /// @dev May only be called by the game master.
    ///      Cannot be called again if a winner is found in a prior round 
    ///      or if the maximum number of rounds have been played.
    function playRound() external onlyGameMaster returns (uint8 winnerIdx) {
        require(!t_inRound.load(), AlreadyInRoundError());
        t_inRound.store(true);
        uint16 round_ = _round;
        require(round_ < MAX_ROUNDS, GameOverError());
        _resupply();
        _buildBlock();
        emit RoundPlayed(round_);
        {
            IPlayer winner = _findWinner(round_ + 1);
            if (winner != NULL_PLAYER) {
                winnerIdx = getIndexFromPlayer(winner);
                // Invert the round counter to end the game early.
                _round = (round_ = ~(++round_));
                assert(round_ >= MAX_ROUNDS);
            } else {
                winnerIdx = INVALID_PLAYER_IDX;
                _round = ++round_;
            }
        }
        t_inRound.store(false);
        if (winnerIdx != INVALID_PLAYER_IDX) {
            emit GameOver(_getTrueRoundCount(round_), winnerIdx);
        }
    }

    /// @inheritdoc IGame
    function sell(uint8 fromAssetIdx, uint8 toAssetIdx, uint256 fromAmount)
        external onlyBuilder returns (uint256 toAmount)
    {
        // Caller must be builder, which is always a valid player.
        uint8 playerIdx = getIndexFromPlayer(IPlayer(msg.sender));
        return _sellAs(playerIdx, fromAssetIdx, toAssetIdx, fromAmount);
    }

    /// @inheritdoc IGame
    function buy(uint8 fromAssetIdx, uint8 toAssetIdx, uint256 toAmount)
        external onlyBuilder returns (uint256 fromAmount)
    {
        // Caller must be builder, which is always a valid player.
        uint8 playerIdx = getIndexFromPlayer(IPlayer(msg.sender));
        return _buyAs(playerIdx, fromAssetIdx, toAssetIdx, toAmount);
    }

    /// @dev Build a block as player `builderIdx` and revert state.
    function buildPlayerBlockAndRevert(uint8 builderIdx)
        external onlySelf
    {
        revert BuildPlayerBlockAndRevertSuccess(_buildPlayerBlock(builderIdx));
    }

    /// @inheritdoc IGame
    function settleBundle(uint8 playerIdx, PlayerBundle memory bundle)
        external onlyBuilder returns (bool success)
    {
        require(playerIdx < playerCount, InvalidPlayerError());
        {
            uint16 round_ = _round;
            {
                bytes32 lastHash = _getPlayerLastBundleHash(playerIdx);
                if (lastHash != 0 && getRoundFromBundleHash(lastHash) >= round_) {
                    revert BundleAlreadySettledError(playerIdx);
                }
            }
            _setPlayerLastBundleHash(playerIdx, getBundleHash(bundle, round_));
        }
        if (gasleft() < MIN_GAS_PER_BUNDLE_SWAP * bundle.swaps.length + 2e3) {
            revert InsufficientBundleGasError();
        }
        try this.selfSettleBundle(playerIdx, bundle) {
            success = true;
        } catch {
            // If settlement fails, ignore it.
        }
        emit BundleSettled(playerIdx, success, bundle);
        return success;
    }

    /// @dev Attempt to settle a bundle. Can only be called by self.
    ///      Allows the caller (us) to handle a revert.
    function selfSettleBundle(uint8 playerIdx, PlayerBundle memory bundle)
        external onlySelf
    {
        for (uint256 i; i < bundle.swaps.length; ++i) {
            SwapSell memory swap = bundle.swaps[i];
            if (swap.fromAmount == 0 || swap.fromAssetIdx == swap.toAssetIdx) {
                continue;
            }
            _sellAs(playerIdx, swap.fromAssetIdx, swap.toAssetIdx, swap.fromAmount);
        }
    }

    /// @dev Search for a player that either matches the win condition or 
    ///      is the closest if the maximum number of rounds have been played.
    ///      Returns `NULL_PLAYER` if none can be found.
    function _findWinner(uint16 round_)
        internal virtual view returns (IPlayer winner)
    {
        // Find which player has the maximum balance of any asset that isn't gold.
        uint8 maxBalancePlayerIdx;
        uint8 maxBalanceAssetIdx;
        uint256 maxBalance;
        for (uint8 playerIdx; playerIdx < playerCount; ++playerIdx) {
           (uint8 assetIdx, uint256 assetBalance) = _getMaxNonGoldAssetForPlayer(playerIdx);
            if (assetBalance > maxBalance) {
                maxBalancePlayerIdx = playerIdx;
                maxBalanceAssetIdx = assetIdx;
                maxBalance = assetBalance;
            }
        }
        if (round_ < MAX_ROUNDS) {
            // If not at max rounds, the winner is whomever has at least the minimum
            // winning asset balance.
            if (maxBalanceAssetIdx != 0 && maxBalance >= MIN_WINNING_ASSET_BALANCE) {
                return _playerByIdx[maxBalancePlayerIdx];
            }
            return NULL_PLAYER;
        }
        return _playerByIdx[maxBalancePlayerIdx];
    }

    /// @dev Get the maximum amount of a non-gold asset for a player.
    function _getMaxNonGoldAssetForPlayer(uint8 playerIdx)
        internal view returns (uint8 assetIdx, uint256 balance)
    {
        uint8 nAssets = ASSET_COUNT;
        for (assetIdx = GOLD_IDX + 1; assetIdx < nAssets; ++assetIdx) {
            uint256 bal = balanceOf[playerIdx][assetIdx];
            if (bal > balance) {
                assetIdx = assetIdx;
                balance = bal;
            }
        }
    }

    /// @dev Cleans the "winner found" upper bits from the raw round
    ///      counter (`_round`).
    function _getTrueRoundCount(uint16 rawRound) private pure returns (uint16 round_) {
        return rawRound & 0x8000 != 0 ? ~rawRound : rawRound;
    }

    /// @dev Esnure an asset index is valid.
    function _assertValidAsset(uint8 assetIdx) private view {
        require(assetIdx < ASSET_COUNT, InvalidAssetError());
    }

    /// @dev Asks each player to create a bundle for the round under
    ///      the given builder.
    function _getPlayerBundles(uint8 builderIdx)
        internal returns (PlayerBundle[] memory bundles)
    {
        uint8 n = playerCount;
        bundles = new PlayerBundle[](n);
        for (uint8 playerIdx; playerIdx < n; ++playerIdx) {
            uint256 gasUsed = gasleft();
            try this.selfCallPlayerCreateBundle(playerIdx, builderIdx)
                returns (PlayerBundle memory bundle)
            {
                bundles[playerIdx] = bundle;
            } catch (bytes memory errData) {
                // createBundle() failed. Treat it as if the player returned
                // nothing.
                emit CreateBundleFailed(playerIdx, builderIdx, errData);
                continue;
            }
            gasUsed -= gasleft(); 
            emit PlayerBundleGasUsage(playerIdx, uint32(gasUsed));
        }
    }

    /// @dev Simulates a player building the current block.
    function _simulateBuildPlayerBlock(uint8 builderIdx)
        internal returns (uint256 bid)
    {
        uint256 gasUsed = gasleft();
        try this.buildPlayerBlockAndRevert(builderIdx) {
            // Call must revert.
            assert(false);
        } catch (bytes memory data) {
            gasUsed -= gasleft(); 
            emit PlayerBlockGasUsage(builderIdx, uint32(gasUsed));
            bytes4 selector = data.getSelectorOr(bytes4(0));
            if (selector == BuildPlayerBlockAndRevertSuccess.selector) {
                data = data.trimLeadingBytesDestructive(4);
                bid = abi.decode(data, (uint256));
            } else {
                emit BuildPlayerBlockFailed(builderIdx, data);
            }
        }
    }

    /// @dev Build the current block as player `builderIdx`.
    ///      Reverts from player callbacks will either be wrapped or ignored.
    function _buildPlayerBlock(uint8 builderIdx)
        internal returns (uint256 bid)
    {
        IPlayer builder = _playerByIdx[builderIdx];
        assert(IPlayer(t_currentBuilder.load()) == NULL_PLAYER);
        t_currentBuilder.store(address(builder));
        PlayerBundle[] memory bundles = _getPlayerBundles(builderIdx);
        {
            bool success;
            bytes memory errData;
            (success, bid, errData) = _safeCallPlayerBuild(builder, bundles);
            require(success, BuildBlockFailedError(builderIdx, errData));
        }
        // If bid is zero this block will be ignored anyway, so no need to
        // do more checks.
        if (bid != 0) {
            // All player bundles must be executed (excluding the builder's).
            uint16 round_ = _round;
            for (uint8 playerIdx; playerIdx < bundles.length; ++playerIdx) {
                if (playerIdx != builderIdx) {
                    // If the builder did not settle this player's bundle
                    // or modified this player's bundle, revert.
                    if (_getPlayerLastBundleHash(playerIdx) !=
                        getBundleHash(bundles[playerIdx], round_))
                    {
                        revert BundleNotSettledError(builderIdx, playerIdx);
                    }
                }
            }
            // Burn the bid. This will revert if the player does not have
            // enough gold.
            _burn(builderIdx, GOLD_IDX, bid);
        }
        t_currentBuilder.store(address(NULL_PLAYER));
    }

    /// @dev Safely call a player's `buildBlock()` function, with fixed gas,
    ///      returnData limits, and without bubbling up reverts.
    function _safeCallPlayerBuild(IPlayer builder, PlayerBundle[] memory bundles)
        internal returns (bool success, uint256 bid, bytes memory errData)
    {
        bytes memory resultData;
        (success, resultData) = address(builder).safeCall(
            abi.encodeCall(IPlayer.buildBlock, (bundles)),
            false,
            PLAYER_BUILD_BLOCK_GAS_BASE + PLAYER_BUILD_BLOCK_GAS_PER_PLAYER * playerCount,
            MAX_RETURN_DATA_SIZE
        );
        if (!success || resultData.length != 32) {
            errData = resultData;
        } else {
            bid = abi.decode(resultData, (uint256));
        }
    }

    /// @dev Safely and externally call a player's `createBundle()` function,
    ///      with fixed gas, returnData limits, and without bubbling up reverts.
    ///      Only this contract can call this function.
    function selfCallPlayerCreateBundle(uint8 playerIdx, uint8 builderIdx)
        external onlySelf returns (PlayerBundle memory bundle)
    {
        IPlayer player = _playerByIdx[playerIdx];
        (bool success, bytes memory resultData) = address(player).safeCall(
            abi.encodeCall(IPlayer.createBundle, (builderIdx)),
            false,
            PLAYER_CREATE_BUNDLE_GAS_BASE + PLAYER_CREATE_BUNDLE_GAS_PER_PLAYER * playerCount,
            MAX_RETURN_DATA_SIZE
        );
        if (!success) {
            resultData.rawRevert();
        } else {
            bundle = abi.decode(resultData, (PlayerBundle));
            require(bundle.swaps.length <= ASSET_COUNT * (ASSET_COUNT-1), TooManySwapsError());
        }
    }

    /// @dev Auction the current block to all players.
    ///      We will simulate the block being built by each player and
    ///      chose the player with the highest (successful) bid.
    function _auctionBlock()
        internal virtual returns (uint8 builderIdx, uint256 builderBid)
    {
        builderIdx = INVALID_PLAYER_IDX;
        for (uint8 i; i < playerCount; ++i) {
            uint256 bid = _simulateBuildPlayerBlock(i);
            if (bid != 0) {
                emit BlockBid(i, bid);
                if (bid > builderBid) {
                    builderBid = bid;
                    builderIdx = i;
                }
            }
        }
    }

    /// @dev Build the block for the round by conducting a builder auction.
    ///      If no one wins (they all bid or fail), an empty block occurs, 
    ///      which means NO bundles are settled this round.
    function _buildBlock() internal {
        (uint8 builderIdx, uint256 builderBid) = _auctionBlock();
        if (builderIdx != INVALID_PLAYER_IDX && builderBid != 0) {
            assert(_buildPlayerBlock(builderIdx) == builderBid);
            lastBuilder = builderIdx;
            lastWinningBid = builderBid;
            emit BlockBuilt(_round, builderIdx, builderBid);
        } else {
            lastWinningBid = 0;
            emit EmptyBlock(_round);
        }
    }

    /// @dev Grant each player an equal amount of assets.
    function _resupply() internal virtual {
        uint8 numAssets = ASSET_COUNT;
        for (uint8 playerIdx; playerIdx < playerCount; ++playerIdx) {
            for (uint8 assetIdx; assetIdx < numAssets; ++assetIdx) {
                _mint({
                    playerIdx: playerIdx,
                    assetIdx: assetIdx,
                    assetAmount: assetIdx == GOLD_IDX
                        ? GOLD_INCOME_AMOUNT
                        : GOODS_INCOME_AMOUNT
                });
            }
        }
    }

    /// @dev Mint an asset for a player.
    function _mint(uint8 playerIdx, uint8 assetIdx, uint256 assetAmount) internal {
        _assertValidAsset(assetIdx);
        if (assetAmount == 0) return;
        balanceOf[playerIdx][assetIdx] += assetAmount;
        emit Mint(playerIdx, assetIdx, assetAmount);
    }

    /// @dev Burn an asset from a player.
    function _burn(uint8 playerIdx, uint8 assetIdx, uint256 assetAmount) internal {
        _assertValidAsset(assetIdx);
        if (assetAmount == 0) return;
        uint256 bal = balanceOf[playerIdx][assetIdx];
        require(bal >= assetAmount, InsufficientBalanceError(playerIdx, assetIdx));
        unchecked {
            balanceOf[playerIdx][assetIdx] = bal - assetAmount;
        }
        emit Burn(playerIdx, assetIdx, assetAmount);
    }

    /// @dev Sell an asset as a player.
    function _sellAs(uint8 playerIdx, uint8 fromAssetIdx, uint8 toAssetIdx, uint256 fromAmount)
        internal returns (uint256 toAmount)
    {
        _assertValidAsset(fromAssetIdx);
        _assertValidAsset(toAssetIdx);
        _burn(playerIdx, fromAssetIdx, fromAmount);
        toAmount = AssetMarket._sell(fromAssetIdx, toAssetIdx, fromAmount);
        _mint(playerIdx, toAssetIdx, toAmount);
        emit Swap(playerIdx, fromAssetIdx, toAssetIdx, fromAmount, toAmount);
    }

    /// @dev Buy an asset as a player.
    function _buyAs(uint8 playerIdx, uint8 fromAssetIdx, uint8 toAssetIdx, uint256 toAmount)
        internal returns (uint256 fromAmount)
    {
        _assertValidAsset(fromAssetIdx);
        _assertValidAsset(toAssetIdx);
        fromAmount = AssetMarket._buy(fromAssetIdx, toAssetIdx, toAmount);
        _burn(playerIdx, fromAssetIdx, fromAmount);
        _mint(playerIdx, toAssetIdx, toAmount);
        emit Swap(playerIdx, fromAssetIdx, toAssetIdx, fromAmount, toAmount);
    }

    function _getPlayerLastBundleHash(uint8 playerIdx)
        private view returns (bytes32 hash)
    {
        return t_playerBundleHash.load(playerIdx);
    }

    function _setPlayerLastBundleHash(uint8 playerIdx, bytes32 hash) private {
        t_playerBundleHash.store(playerIdx, hash);
    }
}
