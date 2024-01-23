// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { AssetMarket } from './Markets.sol';
import { LibBytes } from './LibBytes.sol';
import { LibAddress } from './LibAddress.sol';
import { IPlayer } from './IPlayer.sol';

contract Game is AssetMarket {
    using LibBytes for bytes;
    using LibAddress for address;

    // Bounded by size of `_isPlayerIncludedInRoundBitmap` and address suffix.
    uint256 public constant MAX_PLAYERS = 8;
    uint8 public constant MAX_ROUNDS = 101;
    uint256 public constant MIN_WINNING_ASSET_BALANCE = 100e18;
    uint256 internal constant MARKET_STARTING_GOLD = 200e18;
    uint256 internal constant MARKET_STARTING_GOODS = 100e18;
    uint8 constant GOLD_IDX = 0;
    uint8 constant INVALID_PLAYER_IDX = type(uint8).max;
    uint256 constant MAX_TURN_GAS = 32e3;
    uint256 constant MAX_BUILD_GAS = 256e3;
    uint256 constant MAX_RETURN_DATA_SIZE = 8192;
    uint160 constant PLAYER_ADDRESS_INDEX_MASK = 7;

    address public immutable GM;

    uint8 public playerCount;
    uint16 _round;
    bool _inRound;
    mapping (uint8 playerIdx => mapping (uint8 assetIdx => uint256 balance)) public balanceOf;
    mapping (uint8 playerIdx => IPlayer player) _playerByIdx;
    IPlayer _builder;
    uint8 _isPlayerIncludedInRoundBitmap;

    error GameOverError();
    error GameSetupError(string msg);
    error AccessError();
    error InsufficientBalanceError(uint8 playerIdx, uint8 assetIdx);
    error InvalidPlayerError();
    error PlayerMissingFromBlockError(uint8 builderIdx);
    error PlayerBuildBlockFailedError(uint8 builderIdx, bytes revertData);
    error OnlySelfError();
    error PlayerAlreadyIncludedError(uint8 playerIdx);
    error BuildPlayerBlockAndRevertSuccess(uint256 bid);
    
    event RoundPlayed(uint16 round);
    event PlayerTurnFailedWarning(uint8 playerIdx, bytes revertData);
    event GameWon(uint8 indexed playerIdx, uint16 round);
    event Mint(uint8 indexed playerIdx, uint8 indexed assetIdx, uint256 assetAmount);
    event Burn(uint8 indexed playerIdx, uint8 indexed assetIdx, uint256 assetAmount);
    event Transfer(uint8 indexed fromPlayerIdx, uint8 indexed  toPlayerIdx, uint8 indexed assetIdx, uint256 assetAmount);
    event BlockBid(uint8 indexed playerIdx, uint256 bid);
    event PlayerBlockBuilt(uint16 round, uint8 indexed builderIdx);
    event DefaultBlockBuilt(uint16 round);
    event BuildPlayerBlockFailedWarning(bytes data);
    event Swap(uint8 playerIdx, uint8 fromAssetIdx, uint8 toAssetIdx, uint256 fromAmount, uint256 toAmount);

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

    constructor(bytes[] memory playerCreationCodes, uint256[] memory deploySalts)
        AssetMarket(uint8(playerCreationCodes.length))
    {
        if (playerCreationCodes.length != deploySalts.length) {
            revert GameSetupError('mismatched arrays');
        }
        GM = msg.sender;
        uint256 playerCount_ = playerCreationCodes.length;
        if (playerCount_ < 2 || playerCount_ > MAX_PLAYERS) {
            revert GameSetupError('# of players');
        }
        playerCount = uint8(playerCreationCodes.length);
        {
            bytes memory initArgs = abi.encode(0, playerCount_);
            for (uint8 i; i < playerCount_; ++i) {
                assembly ("memory-safe") { mstore(add(initArgs, 0x20), i) }
                IPlayer player = IPlayer(playerCreationCodes[i].create2(
                    deploySalts[i],
                    0,
                    initArgs
                ));
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
        _auctionBlock(players, round_);
        {
            IPlayer winner = _findWinner(uint8(players.length), round_);
            if (address(winner) != address(0)) {
                winnerIdx = _getIndexFromPlayer(winner);
                emit GameWon(winnerIdx, round_);
                // Invert the round counter to end the game early.
                _round = (round_ = ~round_);
                assert(round_ >= MAX_ROUNDS);
            } else {
                emit RoundPlayed(round_);
                winnerIdx = INVALID_PLAYER_IDX;
                _round = ++round_;
            }
        }
        _inRound = false;
    }
    
    function findWinner() external view returns (bool hasWinner, uint8 winnerIdx) {
        IPlayer winner = _findWinner(playerCount, _round);
        return address(winner) == address(0) ? (false, 0) : (true, _getIndexFromPlayer(winner));
    }

    function transfer(uint8 toPlayerIdx, uint8 assetIdx, uint256 amount) public {
        if (!_inRound) revert AccessError();
        uint8 fromPlayerIdx = _getIndexFromPlayer(IPlayer(msg.sender));
        _assertValidAsset(assetIdx);
        // Sender and receiver must be players.
        if (address(_playerByIdx[fromPlayerIdx]) != msg.sender ||
            address(_playerByIdx[toPlayerIdx]) == address(0))
        {
            revert AccessError();
        }
        uint256 fromBal = balanceOf[fromPlayerIdx][assetIdx];
        if (fromBal < amount) revert InsufficientBalanceError(fromPlayerIdx, assetIdx);
        balanceOf[fromPlayerIdx][assetIdx] = fromBal - amount;
        balanceOf[toPlayerIdx][assetIdx] += amount;
        emit Transfer(fromPlayerIdx, toPlayerIdx, assetIdx, amount);
    }

    function takeTurn(uint8 playerIdx) external onlyBuilder returns (bool success) {
        IPlayer player = _playerByIdx[playerIdx];
        if (address(player) == address(0)) revert InvalidPlayerError();
        {
            // Check and update the player inclusion bitmap.
            uint8 bitmap = _isPlayerIncludedInRoundBitmap;
            uint8 playerBit = uint8(1 << playerIdx);
            if (bitmap & playerBit != 0) {
                revert PlayerAlreadyIncludedError(playerIdx);
            }
            _isPlayerIncludedInRoundBitmap = bitmap | playerBit;
        }
        return _safeCallTurn(player, _getIndexFromPlayer(_builder));
    }

    function sell(uint8 fromAssetIdx, uint8 toAssetIdx, uint256 fromAmount)
        external returns (uint256 toAmount)
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
        external returns (uint256 fromAmount)
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
        return _buildPlayerBlock(_getAllPlayers(), _getIndexFromPlayer(builder));
    }

    function round() public view returns (uint16 round_) {
        round_ = _round;
        if (round_ & 0x8000 != 0) {
            round_ = ~round_;
        }
    }

    function isGameOver() public view returns (bool) {
        return _round >= MAX_ROUNDS;
    }

    function _findWinner(uint8 playerCount_, uint16 round_)
        private view returns (IPlayer winner)
    {
        // Find which player has the maximum balance of any asset that isn't gold.
        uint8 nAssets = ASSET_COUNT;
        uint8 maxBalancePlayerIdx;
        uint8 maxBalanceAssetIdx;
        uint256 maxBalance;
        for (uint8 playerIdx; playerIdx < playerCount_; ++playerIdx) {
            for (uint8 assetIdx = GOLD_IDX + 1; assetIdx < nAssets; ++assetIdx) {
                uint256 bal = balanceOf[playerIdx][assetIdx];
                if (bal > maxBalance) {
                    maxBalancePlayerIdx = playerIdx;
                    maxBalanceAssetIdx = assetIdx;
                    maxBalance = bal;
                }
            }
        }
        if (round_ < MAX_ROUNDS) {
            // If not at max rounds, the winner is whomever has at least the minimum
            // winning asset balance.
            if (maxBalanceAssetIdx != 0 && maxBalance >= MIN_WINNING_ASSET_BALANCE) {
                return _playerByIdx[maxBalancePlayerIdx];
            }
            return IPlayer(address(0));
        }
        // After max rounds, whomever has the highest balance wins.
        return _playerByIdx[maxBalancePlayerIdx];
    }

    function _auctionBlock(IPlayer[] memory players, uint16 round_) private {
        uint256 maxBid;
        uint8 maxBidPlayerIdx;
        for (uint8 i; i < players.length; ++i) {
            uint256 bid = _simulateBuildPlayerBlock(players, i);
            if (bid != 0) emit BlockBid(i, bid);
            if (bid > maxBid) {
                maxBid = bid;
                maxBidPlayerIdx = i;
            }
        }
        if (maxBid != 0) {
            assert(_buildPlayerBlock(players, maxBidPlayerIdx) == maxBid);
            emit PlayerBlockBuilt(round_, maxBidPlayerIdx);
        } else {
            _buildDefaultBlock(players, round_);
            emit DefaultBlockBuilt(round_);
        }
    }

    function _simulateBuildPlayerBlock(IPlayer[] memory players, uint8 builderIdx)
        private returns (uint256 bid)
    {
        IPlayer builder = players[builderIdx];
        try this.buildPlayerBlockAndRevert(builder) {
            // Call must revert.
            assert(false);
        } catch (bytes memory data) {
            bytes4 selector = data.getSelectorOr(bytes4(0));
            if (selector == BuildPlayerBlockAndRevertSuccess.selector) {
                data.trimLeadingBytesDestructive(4);
                bid = abi.decode(data, (uint256));
            } else {
                emit BuildPlayerBlockFailedWarning(data);
            }
        }
    }

    function _buildPlayerBlock(IPlayer[] memory players, uint8 builderIdx)
        private returns (uint256 bid)
    {
        IPlayer builder = players[builderIdx];
        assert(address(_builder) == address(0));
        (_builder, _isPlayerIncludedInRoundBitmap) = (builder, 0);
        {
            bool success;
            bytes memory errData;
            (success, bid, errData) = _safeCallPlayerBuild(builder);
            if (!success) {
                revert PlayerBuildBlockFailedError(builderIdx, errData);
            }
        }
        // All players must be included in the block.
        if (_isPlayerIncludedInRoundBitmap != (1 << players.length) - 1) {
            revert PlayerMissingFromBlockError(builderIdx);
        }
        _burnAssetFrom(builderIdx, GOLD_IDX, bid);
        _builder = IPlayer(address(0));
    }

    function _safeCallPlayerBuild(IPlayer builder)
        private returns (bool success, uint256 bid, bytes memory errData)
    {
        bytes memory resultData;
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

    function _buildDefaultBlock(IPlayer[] memory players, uint16 round_) private {
        // Default blocks just use round-robin ordering of players.
        for (uint8 i; i < players.length; ++i) {
            _safeCallTurn(players[(round_ + i) % players.length], INVALID_PLAYER_IDX);
        }
    }

    function _safeCallTurn(IPlayer player, uint8 builderIdx) private returns (bool success) {
        bytes memory resultData;
        (success, resultData) = address(player).safeCall(
            abi.encodeCall(IPlayer.turn, (builderIdx)),
            false, 
            MAX_TURN_GAS,
            MAX_RETURN_DATA_SIZE
        );
        if (!success) {
            emit PlayerTurnFailedWarning(_getIndexFromPlayer(player), resultData);
        }
    }

    function _getAllPlayers() private view returns (IPlayer[] memory players) {
        uint8 n = playerCount;
        players = new IPlayer[](n);
        for (uint8 i; i < n; ++i) {
            players[i] = _playerByIdx[i];
        }
    }

    function _getValidPlayerIdx(IPlayer player) private view returns (uint8 playerIdx) {
        playerIdx = _getIndexFromPlayer(player);
        if (_playerByIdx[playerIdx] != player) revert InvalidPlayerError();
    }

    function _getIndexFromPlayer(IPlayer player) private pure returns (uint8 playerIdx) {
        // The deployment process in the constructor ensures that the lowest 3 bits of the
        // player's address is also its player index.
        return uint8(uint160(address(player)) & PLAYER_ADDRESS_INDEX_MASK);
    }

    function _distributeIncome(IPlayer[] memory players) private {
        uint8 numAssets = ASSET_COUNT;
        // Mint 1 unit of each type of asset to each player.
        for (uint8 playerIdx; playerIdx < players.length; ++playerIdx) {
            for (uint8 assetIdx; assetIdx < numAssets; ++assetIdx) {
                _mintAssetTo({playerIdx: playerIdx, assetIdx: assetIdx, assetAmount: 1 ether});
            }
        }
    }

    function _mintAssetTo(uint8 playerIdx, uint8 assetIdx, uint256 assetAmount) private {
        balanceOf[playerIdx][assetIdx] += assetAmount;
        emit Mint(playerIdx, assetIdx, assetAmount);
    }

    function _burnAssetFrom(uint8 playerIdx, uint8 assetIdx, uint256 assetAmount) private {
        uint256 bal = balanceOf[playerIdx][assetIdx];
        if (bal < assetIdx) revert InsufficientBalanceError(playerIdx, assetIdx);
        balanceOf[playerIdx][assetIdx] = bal - assetAmount;
        emit Burn(playerIdx, assetIdx, assetAmount);
    }

    function _assertValidAsset(uint8 assetIdx) private view {
        if (assetIdx >= ASSET_COUNT) revert InvalidAssetError();
    }
}
