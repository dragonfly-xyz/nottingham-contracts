// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { AssetMarket } from './Markets.sol';
import { LibBytes } from './LibBytes.sol';
import { LibAddress } from './LibAddress.sol';
import { IPlayer } from './IPlayer.sol';
import { SafeCreate2 } from './SafeCreate2.sol';

IPlayer constant NULL_PLAYER = IPlayer(address(0));
IPlayer constant DEFAULT_BUILDER = IPlayer(address(type(uint160).max));
uint160 constant PLAYER_ADDRESS_INDEX_MASK = 7;
uint8 constant GOLD_IDX = 0;
uint256 constant MIN_PLAYERS = 2;
// Bounded by size of `_isPlayerIncludedInRoundBitmap` and address suffix.
uint256 constant MAX_PLAYERS = 8;
uint8 constant MAX_ROUNDS = 32;
uint256 constant MIN_WINNING_ASSET_BALANCE = 32e18;
uint256 constant MARKET_STARTING_GOLD = 200e18;
uint256 constant MARKET_STARTING_GOODS = 100e18;
uint8 constant INVALID_PLAYER_IDX = type(uint8).max;
uint256 constant MAX_CREATION_GAS = 8e6;
uint256 constant MAX_TURN_GAS = 2e6;
uint256 constant MAX_BUILD_GAS = 16e6;
uint256 constant MAX_RETURN_DATA_SIZE = 1024;
uint256 constant INCOME_AMOUNT = 1e18;

function getIndexFromPlayer(IPlayer player) pure returns (uint8 playerIdx) {
    // The deployment process in the constructor ensures that the lowest 3 bits of the
    // player's address is also its player index.
    return uint8(uint160(address(player)) & PLAYER_ADDRESS_INDEX_MASK);
}

contract Game is AssetMarket {
    using LibBytes for bytes;
    using LibAddress for address;

    address public immutable GM;
    uint8 public immutable PLAYER_COUNT;

    uint16 internal _round;
    bool _inRound;
    uint8 _isPlayerIncludedInRoundBitmap;
    IPlayer _builder;
    mapping (uint8 playerIdx => mapping (uint8 assetIdx => uint256 balance)) public balanceOf;
    mapping (uint8 playerIdx => IPlayer player) internal  _playerByIdx;

    error GameOverError();
    error GameSetupError(string msg);
    error AccessError();
    error DuringBlockError();
    error InsufficientBalanceError(uint8 playerIdx, uint8 assetIdx);
    error InvalidPlayerError();
    error PlayerMissingFromBlockError(uint8 builderIdx);
    error PlayerBuildBlockFailedError(uint8 builderIdx, bytes revertData);
    error OnlySelfError();
    error PlayerAlreadyIncludedError(uint8 playerIdx);
    error BuildPlayerBlockAndRevertSuccess(uint256 bid);
    error MinGasError();
    
    event CreatePlayerFailed(uint8 playerIdx);
    event RoundPlayed(uint16 round);
    event PlayerTurnFailed(uint8 playerIdx, bytes revertData);
    event PlayerTurnSuccess(uint8 playerIdx);
    event Mint(uint8 indexed playerIdx, uint8 indexed assetIdx, uint256 assetAmount);
    event Burn(uint8 indexed playerIdx, uint8 indexed assetIdx, uint256 assetAmount);
    event BlockBid(uint8 indexed playerIdx, uint256 bid);
    event PlayerBlockBuilt(uint16 round, uint8 indexed builderIdx);
    event DefaultBlockBuilt(uint16 round);
    event BuildPlayerBlockFailedWarning(bytes data);
    event Swap(uint8 playerIdx, uint8 fromAssetIdx, uint8 toAssetIdx, uint256 fromAmount, uint256 toAmount);
    event GameOver(uint16 rounds, uint8 winnerIdx); 
    event PlayerBlockGasUsage(uint8 builderIdx, uint256 gasUsed);

    modifier onlyGameMaster() {
        if (msg.sender != GM) revert AccessError();
        _;
    }
   
    modifier onlyBuilder() {
        if (msg.sender != address(_builder)) revert AccessError();
        _;
    }
   
    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelfError();
        _;
    }

    modifier duringBlock() {
        if (_builder == NULL_PLAYER) revert DuringBlockError();
        _;
    }
   
    modifier minGas(uint256 min) {
        if (gasleft() < min) revert MinGasError();
        _;
    }

    constructor(
        address gameMaster,
        SafeCreate2 sc2,
        bytes[] memory playerCreationCodes,
        uint256[] memory deploySalts
    )
        AssetMarket(uint8(playerCreationCodes.length))
    {
        if (playerCreationCodes.length != deploySalts.length) {
            revert GameSetupError('mismatched arrays');
        }
        GM = gameMaster;
        PLAYER_COUNT = uint8(playerCreationCodes.length);
        if (PLAYER_COUNT < MIN_PLAYERS || PLAYER_COUNT > MAX_PLAYERS) {
            revert GameSetupError('# of players');
        }
        PLAYER_COUNT = uint8(playerCreationCodes.length);
        {
            bytes memory initArgs = abi.encode(0, PLAYER_COUNT);
            for (uint8 i; i < PLAYER_COUNT; ++i) {
                assembly ('memory-safe') { mstore(add(initArgs, 0x20), i) }

                IPlayer player;
                try sc2.safeCreate2{gas: MAX_CREATION_GAS}(
                    playerCreationCodes[i],
                    deploySalts[i],
                    initArgs
                ) returns (address player_) {
                    player = IPlayer(player_);
                } catch {
                    // Assign to empty player address.
                    player = IPlayer(address((255 & (~PLAYER_ADDRESS_INDEX_MASK)) | i));
                    emit CreatePlayerFailed(i);
                }
                // The lowest uint8 of each deployed address should also hold the player index.
                if (uint160(address(player)) & PLAYER_ADDRESS_INDEX_MASK != i) {
                    revert GameSetupError('player index');
                }
                _playerByIdx[i] = player;
            }
        }
        {
            // There will be nplayer assets (incl gold) in the market to ensure
            // at least one asset will be in contention.
            uint8 assetCount_ = uint8(ASSET_COUNT);
            uint256[] memory assetReserves = new uint256[](assetCount_);
            // Initial price is 2:1 gold->good.
            assetReserves[GOLD_IDX] = MARKET_STARTING_GOLD; // Gold is always at asset idx 0.
            for (uint8 i = 1; i < assetCount_; ++i) {
                assetReserves[i] = MARKET_STARTING_GOODS;
            }
            AssetMarket._init(assetReserves);
        }
    }

    function playRound() external onlyGameMaster returns (uint8 winnerIdx) {
        if (_inRound) revert AccessError();
        _inRound = true;
        uint16 round_ = _round;
        if (round_ >= MAX_ROUNDS) revert GameOverError();
        IPlayer[] memory players = _getAllPlayers();
        _distributeIncome(players);
        {
            (uint8 builderIdx, uint256 builderBid) = _auctionBlock(players);
            _buildBlock(round_, players, builderIdx, builderBid);
        }
        emit RoundPlayed(round_);
        {
            IPlayer winner = _findWinner(round_);
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
        _inRound = false;
        if (winnerIdx != INVALID_PLAYER_IDX) {
            emit GameOver(_getTrueRoundCount(round_), winnerIdx);
        }
    }
    
    function findWinner() external view returns (uint8 winnerIdx) {
        IPlayer winner = _findWinner(_round);
        return winner == NULL_PLAYER ? INVALID_PLAYER_IDX : getIndexFromPlayer(winner);
    }

    function scorePlayers() external view returns (uint256[] memory scores) {
        scores = new uint256[](PLAYER_COUNT);
        for (uint8 playerIdx; playerIdx < scores.length; ++playerIdx) {
            (, scores[playerIdx]) = _getMaxNonGoldAssetForPlayer(playerIdx);
        }
    }

    function grantTurn(uint8 playerIdx) 
        external
        minGas(MAX_TURN_GAS + 5e3)
        onlyBuilder
        returns (bool success)
    {
        IPlayer player = _playerByIdx[playerIdx];
        if (player == NULL_PLAYER) revert InvalidPlayerError();
        {
            // Check and update the player inclusion bitmap.
            uint8 bitmap = _isPlayerIncludedInRoundBitmap;
            uint8 playerBit = uint8(1 << playerIdx);
            if (bitmap & playerBit != 0) {
                revert PlayerAlreadyIncludedError(playerIdx);
            }
            _isPlayerIncludedInRoundBitmap = bitmap | playerBit;
        }
        return _safeCallTurn(player, getIndexFromPlayer(_builder));
    }

    function sell(uint8 fromAssetIdx, uint8 toAssetIdx, uint256 fromAmount)
        external duringBlock returns (uint256 toAmount)
    {
        uint8 playerIdx = _getValidPlayerIdx(IPlayer(msg.sender));
        _assertValidAsset(fromAssetIdx);
        _assertValidAsset(toAssetIdx);
        _burnAssetFrom(playerIdx, fromAssetIdx, fromAmount);
        toAmount = AssetMarket._sell(fromAssetIdx, toAssetIdx, fromAmount);
        _mintAssetTo(playerIdx, toAssetIdx, toAmount);
        emit Swap(playerIdx, fromAssetIdx, toAssetIdx, fromAmount, toAmount);
    }

    function buy(uint8 fromAssetIdx, uint8 toAssetIdx, uint256 toAmount)
        external duringBlock returns (uint256 fromAmount)
    {
        uint8 playerIdx = _getValidPlayerIdx(IPlayer(msg.sender));
        _assertValidAsset(fromAssetIdx);
        _assertValidAsset(toAssetIdx);
        fromAmount = AssetMarket._buy(fromAssetIdx, toAssetIdx, toAmount);
        _burnAssetFrom(playerIdx, fromAssetIdx, fromAmount);
        _mintAssetTo(playerIdx, toAssetIdx, toAmount);
        emit Swap(playerIdx, fromAssetIdx, toAssetIdx, fromAmount, toAmount);
    }

    function quoteSell(uint8 fromAssetIdx, uint8 toAssetIdx, uint256 fromAmount)
        external view returns (uint256 toAmount)
    {
        _assertValidAsset(fromAssetIdx);
        _assertValidAsset(toAssetIdx);
        return AssetMarket._quoteSell(fromAssetIdx, toAssetIdx, fromAmount);
    }

    function quoteBuy(uint8 fromAssetIdx, uint8 toAssetIdx, uint256 toAmount)
        external view returns (uint256 fromAmount)
    {
        _assertValidAsset(fromAssetIdx);
        _assertValidAsset(toAssetIdx);
        return AssetMarket._quoteBuy(fromAssetIdx, toAssetIdx, toAmount);
    }

    function marketState() external view returns (uint256[] memory reserves) {
        reserves = new uint256[](ASSET_COUNT);
        for (uint8 assetIdx; assetIdx < ASSET_COUNT; ++assetIdx) {
            reserves[assetIdx] = AssetMarket._getReserve(assetIdx);
        }
        return reserves;
    }

    function buildPlayerBlockAndRevert(IPlayer builder) external {
        revert BuildPlayerBlockAndRevertSuccess(this.selfBuildPlayerBlock(builder));
    }

    function selfBuildPlayerBlock(IPlayer builder)
        external onlySelf returns (uint256 bid)
    {
        return _buildPlayerBlock(_getAllPlayers(), getIndexFromPlayer(builder));
    }

    function round() public view returns (uint16 round_) {
        return _getTrueRoundCount(_round);
    }

    function assetCount() external view returns (uint8) {
        return ASSET_COUNT;
    }

    function isGameOver() public view returns (bool) {
        return _round >= MAX_ROUNDS;
    }

    function _findWinner(uint16 round_)
        internal virtual view returns (IPlayer winner)
    {
        // Find which player has the maximum balance of any asset that isn't gold.
        uint8 maxBalancePlayerIdx;
        uint8 maxBalanceAssetIdx;
        uint256 maxBalance;
        for (uint8 playerIdx; playerIdx < PLAYER_COUNT; ++playerIdx) {
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

    function _simulateBuildPlayerBlock(IPlayer[] memory players, uint8 builderIdx)
        internal returns (uint256 bid)
    {
        IPlayer builder = players[builderIdx];
        uint256 gasUsed = gasleft();
        try this.buildPlayerBlockAndRevert(builder) {
            // Call must revert.
            assert(false);
        } catch (bytes memory data) {
            gasUsed -= gasleft(); 
            emit PlayerBlockGasUsage(builderIdx, gasUsed);
            bytes4 selector = data.getSelectorOr(bytes4(0));
            if (selector == BuildPlayerBlockAndRevertSuccess.selector) {
                data = data.trimLeadingBytesDestructive(4);
                bid = abi.decode(data, (uint256));
            } else {
                emit BuildPlayerBlockFailedWarning(data);
            }
        }
    }

    function _buildPlayerBlock(IPlayer[] memory players, uint8 builderIdx)
        internal returns (uint256 bid)
    {
        IPlayer builder = players[builderIdx];
        assert(_builder == NULL_PLAYER);
        (_builder, _isPlayerIncludedInRoundBitmap) = (builder, 0);
        {
            bool success;
            bytes memory errData;
            (success, bid, errData) = _safeCallPlayerBuild(builder);
            if (!success) {
                revert PlayerBuildBlockFailedError(builderIdx, errData);
            }
        }
        // All players must be included in the block (excluding the builder).
        uint8 otherPlayerBits = uint8(((1 << players.length) - 1) ^ (1 << builderIdx));
        if (_isPlayerIncludedInRoundBitmap & otherPlayerBits != otherPlayerBits) {
            revert PlayerMissingFromBlockError(builderIdx);
        }
        _burnAssetFrom(builderIdx, GOLD_IDX, bid);
        _builder = NULL_PLAYER;
    }

    function _safeCallPlayerBuild(IPlayer builder)
        internal returns (bool success, uint256 bid, bytes memory errData)
    {
        bytes memory resultData;
        // 63/64 rule protects us from call depth discovery.
        (success, resultData) = address(builder).safeCall(
            abi.encodeCall(IPlayer.buildBlock, ()),
            false,
            MAX_BUILD_GAS,
            MAX_RETURN_DATA_SIZE
        );
        if (!success || resultData.length != 32) {
            errData = resultData;
        } else {
            bid = abi.decode(resultData, (uint256));
        }
    }

    function _buildDefaultBlock(IPlayer[] memory players, uint16 round_) internal virtual {
        assert(_builder == NULL_PLAYER);
        _builder = DEFAULT_BUILDER;
        // Default blocks just use round-robin ordering of players.
        for (uint8 i; i < players.length; ++i) {
            _safeCallTurn(players[(round_ + i) % players.length], INVALID_PLAYER_IDX);
        }
        _builder = NULL_PLAYER;
    }

    function _safeCallTurn(IPlayer player, uint8 builderIdx)
        internal virtual returns (bool success)
    {
        bytes memory resultData;
        // 63/64 rule protects us from call depth discovery.
        (success, resultData) = address(player).safeCall(
            abi.encodeCall(IPlayer.turn, (builderIdx)),
            false, 
            MAX_TURN_GAS,
            MAX_RETURN_DATA_SIZE
        );
        if (!success) {
            emit PlayerTurnFailed(getIndexFromPlayer(player), resultData);
        } else {
            emit PlayerTurnSuccess(getIndexFromPlayer(player));
        }
    }

    function _getTrueRoundCount(uint16 rawRound) private pure returns (uint16 round_) {
        return rawRound & 0x8000 != 0 ? ~rawRound : rawRound;
    }

    function _getValidPlayerIdx(IPlayer player) private view returns (uint8 playerIdx) {
        playerIdx = getIndexFromPlayer(player);
        if (_playerByIdx[playerIdx] != player) revert InvalidPlayerError();
    }

    function _auctionBlock(IPlayer[] memory players)
        internal virtual returns (uint8 builderIdx, uint256 builderBid)
    {
        for (uint8 i; i < players.length; ++i) {
            uint256 bid = _simulateBuildPlayerBlock(players, i);
            if (bid != 0) emit BlockBid(i, bid);
            if (bid > builderBid) {
                builderBid = bid;
                builderIdx = i;
            }
        }
    }

    function _buildBlock(
        uint16 round_,
        IPlayer[] memory players,
        uint8 builderIdx,
        uint256 builderBid
    ) internal {
        if (builderBid != 0) {
            assert(_buildPlayerBlock(players, builderIdx) == builderBid);
            // TODO: Donate bid to market?
            emit PlayerBlockBuilt(round_, builderIdx);
        } else {
            _buildDefaultBlock(players, round_);
            emit DefaultBlockBuilt(round_);
        }
    }

    function _distributeIncome(IPlayer[] memory players) internal virtual {
        uint8 numAssets = ASSET_COUNT;
        // Mint 1 unit of each type of asset to each player.
        for (uint8 playerIdx; playerIdx < players.length; ++playerIdx) {
            for (uint8 assetIdx; assetIdx < numAssets; ++assetIdx) {
                _mintAssetTo({playerIdx: playerIdx, assetIdx: assetIdx, assetAmount: INCOME_AMOUNT});
            }
        }
    }

    function _getAllPlayers() internal view returns (IPlayer[] memory players) {
        uint8 n = PLAYER_COUNT;
        players = new IPlayer[](n);
        for (uint8 i; i < n; ++i) {
            players[i] = _playerByIdx[i];
        }
    }

    function _mintAssetTo(uint8 playerIdx, uint8 assetIdx, uint256 assetAmount) internal {
        balanceOf[playerIdx][assetIdx] += assetAmount;
        emit Mint(playerIdx, assetIdx, assetAmount);
    }

    function _burnAssetFrom(uint8 playerIdx, uint8 assetIdx, uint256 assetAmount) internal {
        uint256 bal = balanceOf[playerIdx][assetIdx];
        if (bal < assetAmount) revert InsufficientBalanceError(playerIdx, assetIdx);
        unchecked {
            balanceOf[playerIdx][assetIdx] = bal - assetAmount;
        }
        emit Burn(playerIdx, assetIdx, assetAmount);
    }

    function _assertValidAsset(uint8 assetIdx) private view {
        if (assetIdx >= ASSET_COUNT) revert InvalidAssetError();
    }

    function getBundleHash(PlayerBundle memory bundle, uint16 round_) public view returns (bytes32 hash) {
        return bytes32((uint256(keccak256(abi.encode(bundle))) & ~uint256(0xFFFF)) | round_);
    }

    function getRoundFromBundleHash(bytes32 hash) public pure returns (uint16 round_) {
        return uint16(uint256(hash) & 0xFFFF);
    }

    error InsufficientBalanceError();

    function fulfill(uint8 playerIdx, PlayerBundle memory bundle)
        external
        onlyBuilder returns (bool success)
    {
        {
            uint16 round_ = _round;
            {
                bytes32 lastHash = _getPlayerLastBundleHash(playerIdx);
                if (lastHash != 0 && getRoundFromBundleHash(lastHash) == round)) {
                    revert PlayerBundleAlreadyFulfilledError();
                }
            }
            _setPlayerLastBundleHash(getBundleHash(bundle, round_));
        }
        if (gasleft() < MIN_GAS_PER_BUNDLE_SWAP * bundle.length + 2e3) {
            revert InsufficientBundleGasError();
        }
        try this.selfSettleBundle(playerIdx, bundle) {
            success = true;
        } catch {}
        emit PlayerBundleFulfilled(playerIdx);
        return success;
    }

    function selfSettleBundle(uint8 playerIdx, PlayerBundle memory bundle) external onlySelf {
        for (uint256 i; i < bundle.swaps.length; ++i) {
            uint256 toAmount = _swap(playerIdx, swap.fromAssetIdx, swap.toAssetIdx, swap.fromAmount);
            if (toAmount < swap.minToAmount) {
                revert SlippageError();
            }
        }
    }

    uint256 constant PLAYER_BUNDLE_HASH_TSLOT = 1;

    function _getPlayerLastBundleHash(uint8 playerIdx) private view returns (bytes32 hash) {
        assembly ('memory-safe') {
            hash := tload(add(PLAYER_BUNDLE_HASH_TSLOT, playerIdx))
        }
    }

    function _setPlayerLastBundleHash(uint8 playerIdx, bytes32 hash) private {
        assembly ('memory-safe') {
            tstore(add(PLAYER_BUNDLE_HASH_TSLOT, playerIdx), hash)
        }
    }
}
