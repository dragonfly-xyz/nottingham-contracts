// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import { Test } from "forge-std/Test.sol";
import { LibTestUtils as T } from "./LibTestUtils.sol";
import {
    Game,
    NULL_PLAYER,
    getIndexFromPlayer,
    MAX_PLAYERS,
    MAX_ROUNDS,
    MIN_WINNING_ASSET_BALANCE,
    GOLD_IDX,
    INVALID_PLAYER_IDX,
    INCOME_AMOUNT,
    MAX_BUILD_GAS
} from "~/Game.sol";
import { IPlayer } from "~/IPlayer.sol";
import { LibBytes } from "~/LibBytes.sol";

enum RevertMode {
    None,
    Revert,
    Invalid
}

event PlayerCreated(address self, uint8 playerIdx, uint8 playerCount);
event Turning(uint16 round, uint8 playerIdx, uint8 builderIdx);
event Building(uint16 round, uint8 playerIdx);
error TestError();

using LibBytes for bytes;

contract GameTest is Test {

    function test_deploysPlayersWithArgs() external {
        address gameAddress = _getNextDeployAddress();
        uint256 playerCount = T.randomUint256() % 5 + 2;
        bytes[] memory creationCodes = new bytes[](playerCount);
        for (uint256 i; i < playerCount; ++i) {
            creationCodes[i] = type(NoopPlayer).creationCode;
        }
        (uint256[] memory salts, IPlayer[] memory players) = _minePlayers(gameAddress, creationCodes);
        for (uint256 i; i < playerCount; ++i) {
            assertEq(uint160(address(players[i])) & 7, i);
            vm.expectEmit(true, true, true, true);
            emit PlayerCreated(address(players[i]), uint8(i), uint8(playerCount));
        }
        Game game = new Game(creationCodes, salts);
        assertEq(address(game), gameAddress); 
    }

    function test_createsNAssets() external {
        uint256 playerCount = T.randomUint256() % 5 + 2;
        bytes[] memory creationCodes = new bytes[](playerCount);
        for (uint256 i; i < playerCount; ++i) {
            creationCodes[i] = type(NoopPlayer).creationCode;
        }
        (Game game,) = _createGame(creationCodes);
        assertEq(game.assetCount(), playerCount);
    }

    function test_cannotDeployGameWithLessThanTwoPlayers() external {
        bytes[] memory creationCodes = new bytes[](1);
        uint256[] memory salts = new uint256[](1);
        vm.expectRevert(abi.encodeWithSelector(Game.GameSetupError.selector, ('# of players')));
        new Game(creationCodes, salts);
    }

    function test_cannotDeployGameWithMoreThanEightPlayers() external {
        bytes[] memory creationCodes = new bytes[](9);
        uint256[] memory salts = new uint256[](9);
        vm.expectRevert(abi.encodeWithSelector(Game.GameSetupError.selector, ('# of players')));
        new Game(creationCodes, salts);
    }

    function test_cannotDeployGameWithFailingPlayerInitCode() external {
        bytes[] memory creationCodes = new bytes[](2);
        creationCodes[0] = hex'fe';
        uint256[] memory salts = new uint256[](2);
        vm.expectRevert(LibBytes.Create2FailedError.selector);
        new Game(creationCodes, salts);
    }
    
    function test_canPlayRoundWithRevertingPlayers() external {
        (Game game,) = _createGame(T.toDynArray([
            type(RevertingPlayer).creationCode,
            type(RevertingPlayer).creationCode
        ]));
        uint8 winnerIdx = game.playRound();
        assertEq(winnerIdx, INVALID_PLAYER_IDX);
    }

    function test_canCompleteGameWithNoopPlayers() external {
        (Game game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 winnerIdx;
        while (true) {
            winnerIdx = game.playRound();
            if (winnerIdx != INVALID_PLAYER_IDX) break;
        }
        assertEq(winnerIdx, 0);
        (uint8 assetIdx, uint256 bal) = _getMaxNonGoldAssetBalance(game, winnerIdx);
        assertTrue(assetIdx != GOLD_IDX);
        assertGe(bal, MIN_WINNING_ASSET_BALANCE);
        assertTrue(game.isGameOver());
    }

    function test_canCompleteGameWithDonatingPlayer() external {
        (Game game,) = _createGame(T.toDynArray([
            type(DonatingPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 winnerIdx;
        while (true) {
            winnerIdx = game.playRound();
            if (winnerIdx != INVALID_PLAYER_IDX) break;
        }
        assertEq(winnerIdx, 1);
        (uint8 assetIdx, uint256 bal) = _getMaxNonGoldAssetBalance(game, winnerIdx);
        assertEq(assetIdx, GOLD_IDX + 1);
        assertGe(bal, MIN_WINNING_ASSET_BALANCE);
        assertEq(game.round(), MAX_ROUNDS / 2 - 1);
        assertTrue(game.isGameOver());
    }

    function test_cannotPlayAnotherRoundAfterWinnerDeclared() external {
        (Game game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 winnerIdx;
        while (true) {
            winnerIdx = game.playRound();
            if (winnerIdx != INVALID_PLAYER_IDX) break;
        }
        assertEq(winnerIdx, 0);
        (uint8 assetIdx, uint256 bal) = _getMaxNonGoldAssetBalance(game, winnerIdx);
        assertTrue(assetIdx != GOLD_IDX);
        assertGe(bal, MIN_WINNING_ASSET_BALANCE);
        assertTrue(game.isGameOver());
        vm.expectRevert(Game.GameOverError.selector);
        game.playRound();
    }

    function test_gameEndsEarlyIfWinnerFound() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setMockWinner(players[1]);
        uint8 winnerIdx = game.playRound();
        assertEq(winnerIdx, 1);
        assertTrue(game.isGameOver());
    }

    function test_distributeIncome_givesOneEtherOfEveryAssetToEveryPlayer() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        uint8 assetCount = game.assetCount();
        for (uint8 playerIdx; playerIdx < players.length; ++playerIdx) {
            for (uint8 assetIdx; assetIdx < assetCount; ++assetIdx) {
                assertEq(game.balanceOf(playerIdx, assetIdx), 0);
            }
        }
        for (uint256 i; i < 3; ++i) {
            game.__distributeIncome();
            for (uint8 playerIdx; playerIdx < players.length; ++playerIdx) {
                for (uint8 assetIdx; assetIdx < assetCount; ++assetIdx) {
                    assertEq(game.balanceOf(playerIdx, assetIdx), 1 ether * (i + 1));
                }
            }
        }
    }

    function test_findWinner_whenBelowMaxRoundsAndPlayerHas100OfANonGoldAsset_returnsThatPlayer() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setRound(MAX_ROUNDS - 1);
        uint8 assetIdx = uint8(1 + T.randomUint256() % (game.assetCount() - 1));
        game.mintAssetTo(players[1], assetIdx, 100 ether);
        uint8 winnerIdx = game.findWinner();
        assertEq(winnerIdx, 1);
    }

    function test_findWinner_whenBelowMaxRoundsAndNoPlayerHas100OfANonGoldAsset_returnsNoWinner() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setRound(MAX_ROUNDS - 1);
        uint8 assetIdx = uint8(1 + T.randomUint256() % (game.assetCount() - 1));
        game.mintAssetTo(players[1], assetIdx, 1 ether - 1);
        uint8 winnerIdx = game.findWinner();
        assertEq(winnerIdx, INVALID_PLAYER_IDX);
    }

    function test_findWinner_whenAtMaxRoundsAndNoPlayerHas100OfANonGoldAsset_returnsPlayerWithMaxBalance() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setRound(MAX_ROUNDS);
        uint8 assetIdx = uint8(1 + T.randomUint256() % (game.assetCount() - 1));
        game.mintAssetTo(players[1], assetIdx, 1 ether - 1);
        uint8 winnerIdx = game.findWinner();
        assertEq(winnerIdx, 1);
    }

    function test_findWinner_whenAtMaxRoundsAndEveryPlayerHasZeroOfANonGoldAsset_returnsNoWinner() external {
        (TestGame game,) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        game.setRound(MAX_ROUNDS);
        uint8 winnerIdx = game.findWinner();
        assertEq(winnerIdx, INVALID_PLAYER_IDX);
    }

    function test_playRound_WinnerBuildsBlock() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(BuilderPlayer).creationCode
        ]));
        BuilderPlayer builder = BuilderPlayer(address(players[1]));
        builder.setBid(1337);
        game.setMockBlockAuctionWinner(players[1], 1337);
        vm.expectCall(address(players[0]), abi.encodeCall(IPlayer.buildBlock, ()), 0);
        vm.expectEmit(true, true, true, true, address(players[1]));
        emit Building(0, 1);
        game.playRound();
        assertEq(game.balanceOf(1, GOLD_IDX), INCOME_AMOUNT - 1337);
    }

    function test_buildBlock_buildsDefaultBlockIfWinningBidIsZero() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        NoopPlayer ignoredBuilder = NoopPlayer(address(players[1]));
        uint16 round = game.round();
        for (uint8 playerIdx; playerIdx < players.length; ++playerIdx) {
            vm.expectEmit(true, true, true, true, address(players[playerIdx]));
            emit Turning(round, playerIdx, INVALID_PLAYER_IDX);
        }
        vm.expectEmit(true, true, true, true, address(game));
        emit Game.DefaultBlockBuilt(0);
        game.__buildBlock(ignoredBuilder, 0);
    }

    function test_buildBlock_buildsPlayerBlockIfWinningBidIsNonZero() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(BuilderPlayer).creationCode
        ]));
        BuilderPlayer builder = BuilderPlayer(address(players[1]));
        builder.setBid(1);
        game.mintAssetTo(builder, GOLD_IDX, 1);
        vm.expectEmit(true, true, true, true);
        emit Game.PlayerBlockBuilt(0, 1);
        game.__buildBlock(builder, 1);
    }

    function test_buildBlock_defaultBlockPlaysAllPlayersInRoundRobinFashion() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        for (uint16 round; round < players.length + 1; ++round) {
            game.setRound(round);
            for (uint8 i; i < players.length; ++i) {
                uint8 playerIdx = uint8((round + i) % players.length);
                vm.expectEmit(true, true, true, true, address(players[playerIdx]));
                emit Turning(round, playerIdx, INVALID_PLAYER_IDX);
            }
            vm.expectEmit(true, true, true, true);
            emit Game.DefaultBlockBuilt(round);
            game.__buildBlock(players[0], 0);
        }
    }

    // function test_buildPlayerBlock_cannotIncludePlayerMoreThanOnce() external {}

    // This state should be unreachable under normal conditions because the auction
    // process will filter out this activity.
    function test_buildBlock_panicsIfBuilderBidsWithDifferentBidThanAuction() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(BuilderPlayer).creationCode
        ]));
        BuilderPlayer builder = BuilderPlayer(address(players[1]));
        builder.setBid(1337);
        vm.expectRevert();
        game.__buildBlock(builder, 1337);
    }

    function test_buildPlayerBlock_failsIfBuilderDoesNotIncludeOtherPlayers() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(BuilderPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        BuilderPlayer builder = BuilderPlayer(address(players[1]));
        builder.setBid(1337);
        builder.ignorePlayer(players[2]);
        vm.expectRevert(abi.encodeWithSelector(Game.PlayerMissingFromBlockError.selector, 1));
        game.__buildPlayerBlock(builder);
    }

    function test_buildPlayerBlock_builderCanExcludeThemself() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(BuilderPlayer).creationCode,
            type(NoopPlayer).creationCode,
            type(NoopPlayer).creationCode
        ]));
        BuilderPlayer builder = BuilderPlayer(address(players[1]));
        game.mintAssetTo(builder, GOLD_IDX, 1337);
        builder.setBid(1337);
        builder.ignorePlayer(builder);
        game.__buildPlayerBlock(builder);
    }

    function test_buildPlayerBlock_failsIfBuilderRevertsDuringBuild() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(BuilderPlayer).creationCode
        ]));
        BuilderPlayer builder = BuilderPlayer(address(players[1]));
        builder.setBid(1337);
        builder.setRevertOnBuild(RevertMode.Revert);
        vm.expectRevert(abi.encodeWithSelector(
            Game.PlayerBuildBlockFailedError.selector,
            1,
            abi.encodeWithSelector(TestError.selector)
        ));
        game.__buildPlayerBlock(builder);
    }

    function test_buildPlayerBlock_failsIfBuilderDoesntHaveFundsAtTheEndOfBlock() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(BuilderPlayer).creationCode
        ]));
        BuilderPlayer builder = BuilderPlayer(address(players[1]));
        builder.setBid(1337);
        builder.addMintOnTurn(builder, GOLD_IDX, 1336);
        vm.expectRevert(abi.encodeWithSelector(
            Game.InsufficientBalanceError.selector,
            1,
            GOLD_IDX
        ));
        game.__buildPlayerBlock(builder);
    }

    function test_buildPlayerBlock_succeedsIfBuilderDoesHaveFundsAtTheEndOfBlock() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(BuilderPlayer).creationCode
        ]));
        BuilderPlayer builder = BuilderPlayer(address(players[1]));
        builder.setBid(1337);
        builder.addMintOnTurn(builder, GOLD_IDX, 1338);
        game.__buildPlayerBlock(builder);
        assertEq(game.balanceOf(1, GOLD_IDX), 1); // 1337 of 1338 is burned.
    }

    function test_buildPlayerBlock_doesNotConsumeAllGasIfBuilderExplodesDuringBuild() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(NoopPlayer).creationCode,
            type(BuilderPlayer).creationCode
        ]));
        BuilderPlayer builder = BuilderPlayer(address(players[1]));
        builder.setBid(1337);
        builder.setRevertOnBuild(RevertMode.Invalid);
        vm.expectRevert(abi.encodeWithSelector(
            Game.PlayerBuildBlockFailedError.selector,
            1,
            ""
        ));
        uint256 gasUsed = gasleft();
        game.__buildPlayerBlock(builder);
        gasUsed -= gasleft();
        assertApproxEqAbs(gasUsed, MAX_BUILD_GAS, 32e3);
    }
   
    // function test_buildPlayerBlock_revertingPlayerCountsAsIncluded() external {}

    function test_auctionBlock_returnsHighestBidder() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(BuilderPlayer).creationCode,
            type(BuilderPlayer).creationCode,
            type(BuilderPlayer).creationCode
        ]));
        BuilderPlayer[] memory builders;
        assembly ("memory-safe") { builders := players }
        game.mintAssetTo(builders[0], GOLD_IDX, 100);
        builders[0].setBid(100);
        game.mintAssetTo(builders[1], GOLD_IDX, 300);
        builders[1].setBid(300);
        game.mintAssetTo(builders[2], GOLD_IDX, 200);
        builders[2].setBid(200);
        (uint8 builderIdx, uint256 bid) = game.__auctionBlock();
        assertEq(builderIdx, 1);
        assertEq(bid, 300);
    }

    function test_auctionBlock_returnsSecondHighestBidderIfHighestReverts() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(BuilderPlayer).creationCode,
            type(BuilderPlayer).creationCode,
            type(BuilderPlayer).creationCode
        ]));
        BuilderPlayer[] memory builders;
        assembly ("memory-safe") { builders := players }
        game.mintAssetTo(builders[0], GOLD_IDX, 100);
        builders[0].setBid(100);
        game.mintAssetTo(builders[1], GOLD_IDX, 300);
        builders[1].setBid(300);
        builders[1].setRevertOnBuild(RevertMode.Revert);
        game.mintAssetTo(builders[2], GOLD_IDX, 200);
        builders[2].setBid(200);
        (uint8 builderIdx, uint256 bid) = game.__auctionBlock();
        assertEq(builderIdx, 2);
        assertEq(bid, 200);
    }

    function test_auctionBlock_returnsZeroIfNoOneBids() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(BuilderPlayer).creationCode,
            type(BuilderPlayer).creationCode,
            type(BuilderPlayer).creationCode
        ]));
        BuilderPlayer[] memory builders;
        assembly ("memory-safe") { builders := players }
        (uint8 builderIdx, uint256 bid) = game.__auctionBlock();
        assertEq(builderIdx, 0);
        assertEq(bid, 0);
    }

    function test_auctionBlock_returnsZeroIfEveryoneReverts() external {
        (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
            type(BuilderPlayer).creationCode,
            type(BuilderPlayer).creationCode,
            type(BuilderPlayer).creationCode
        ]));
        BuilderPlayer[] memory builders;
        assembly ("memory-safe") { builders := players }
        builders[0].setRevertOnBuild(RevertMode.Revert);
        builders[1].setRevertOnBuild(RevertMode.Revert);
        builders[2].setRevertOnBuild(RevertMode.Revert);
        (uint8 builderIdx, uint256 bid) = game.__auctionBlock();
        assertEq(builderIdx, 0);
        assertEq(bid, 0);
    }

    // function test_auctionIgnoresBuilderThatDoesNotIncludeAll() external {
    //     (TestGame game, IPlayer[] memory players) = _createGame(T.toDynArray([
    //         type(NoopPlayer).creationCode,
    //         type(BuilderPlayer).creationCode
    //     ]));
    //     game.setMockBlockAuctionWinner(players[1], 1337);
    //     vm.expectCall(address(players[0]), abi.encodeCall(IPlayer.buildBlock, ()), 0);
    //     vm.expectEmit(true, true, true, true, address(players[1]));
    //     emit Building(0, INCOME_AMOUNT);
    //     game.playRound();
    //     assertEq(game.balanceOf(1, GOLD_IDX), INCOME_AMOUNT - 1337);
    // }

    function arbitraryCall(address target, bytes calldata cd) external {
        (bool s, bytes memory r) = target.call(cd);
        if (!s) r.rawRevert();
    }

    function _createGame(bytes[] memory playerCreationCodes)
        private returns (TestGame game, IPlayer[] memory players)
    {
        uint256[] memory salts;
        (salts, players) = _minePlayers(_getNextDeployAddress(), playerCreationCodes);
        game = new TestGame(playerCreationCodes, salts);
    }

    function _minePlayers(address deployer, bytes[] memory playerCreationCodes)
        private view returns (uint256[] memory salts, IPlayer[] memory players)
    {
        salts = new uint256[](playerCreationCodes.length);
        players = new IPlayer[](playerCreationCodes.length);
        for (uint256 i; i < playerCreationCodes.length; ++i) {
            (salts[i], players[i]) = _findPlayerSaltAndAddress(
                playerCreationCodes[i],
                deployer,
                uint8(i),
                uint8(playerCreationCodes.length)
            );
        }
    }

    function _findPlayerSaltAndAddress(
        bytes memory creationCode,
        address deployer,
        uint8 playerIdx,
        uint8 playerCount
    )
        internal view returns (uint256 salt, IPlayer player)
    {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(creationCode, abi.encode(playerIdx, playerCount)));
        unchecked {
            for (salt = T.randomUint256(); true; ++salt) {
                address addr = T.getCreate2Address(initCodeHash, deployer, salt);
                if ((uint160(addr) & 7) == playerIdx) {
                    return (salt, IPlayer(addr));
                }
            }
        }
    }

    function _getNextDeployAddress() internal view returns (address) {
        return T.getCreateAddress(address(this), vm.getNonce(address(this)));
    }

    function _getMaxAssetBalance(Game game, uint8 playerIdx)
        internal view returns (uint8 maxAssetIdx, uint256 maxAssetBal)
    {
        uint8 assetCount = game.assetCount();
        for (uint8 i; i < assetCount; ++i) {
            uint256 bal = game.balanceOf(playerIdx, i);
            if (bal > maxAssetBal) {
                maxAssetIdx = i;
                maxAssetBal = bal;
            }
        }
    }

    function _getMaxNonGoldAssetBalance(Game game, uint8 playerIdx)
        internal view returns (uint8 maxAssetIdx, uint256 maxAssetBal)
    {
        maxAssetIdx = GOLD_IDX + 1;
        uint8 assetCount = game.assetCount();
        for (uint8 i = GOLD_IDX + 1; i < assetCount; ++i) {
            uint256 bal = game.balanceOf(playerIdx, i);
            if (bal > maxAssetBal) {
                maxAssetIdx = i;
                maxAssetBal = bal;
            }
        }
    }
}

contract TestGame is Game {
    IPlayer public mockWinner;
    IPlayer public mockBuilder;
    uint256 public mockBuilderBid;

    constructor(bytes[] memory playerCreationCodes, uint256[] memory deploySalts)
        Game(playerCreationCodes, deploySalts)
    {}

    function mintAssetTo(IPlayer player, uint8 assetIdx, uint256 assetAmount) external {
        _assertValidPlayer(player);
        _mintAssetTo(getIndexFromPlayer(player), assetIdx, assetAmount);
    }

    function burnAssetFrom(IPlayer player, uint8 assetIdx, uint256 assetAmount) external {
        _assertValidPlayer(player);
        _burnAssetFrom(getIndexFromPlayer(player), assetIdx, assetAmount);
    }

    function setRound(uint16 r) external {
        _round = r;
    }

    function setMockWinner(IPlayer winner) external {
        _assertValidPlayer(winner);
        mockWinner = winner;
    }

    function setMockBlockAuctionWinner(IPlayer builder, uint256 bid) external {
        _assertValidPlayer(builder);
        mockBuilder = builder;
        mockBuilderBid = bid;
    }

    function __distributeIncome() external virtual {
        _distributeIncome(_getAllPlayers());
    }

    function __buildPlayerBlock(IPlayer builder) external returns (uint256 bid) {
        _assertValidPlayer(builder);
        return _buildPlayerBlock(_getAllPlayers(), getIndexFromPlayer(builder));
    }

    function __buildBlock(IPlayer builder, uint256 bid) external {
        _assertValidPlayer(builder);
        return _buildBlock(round(), _getAllPlayers(), getIndexFromPlayer(builder), bid);
    }

    function __auctionBlock() external returns (uint8 builderIdx, uint256 builderBid) {
        return _auctionBlock(_getAllPlayers());
    }

    function _buildDefaultBlock(IPlayer[] memory players, uint16 round_) internal override {
        Game._buildDefaultBlock(players, round_);
    }

    function _safeCallTurn(IPlayer player, uint8 builderIdx)
        internal override returns (bool success)
    {
        return Game._safeCallTurn(player, builderIdx);
    }

    function _auctionBlock(IPlayer[] memory players)
        internal override returns (uint8 builderIdx, uint256 builderBid)
    {
        if (mockBuilder != NULL_PLAYER) {
            return (getIndexFromPlayer(mockBuilder), mockBuilderBid);
        }
        return Game._auctionBlock(players);
    }

    function _findWinner(uint8 playerCount_, uint16 round_)
        internal override view returns (IPlayer winner)
    {
        if (mockWinner != NULL_PLAYER) {
            return mockWinner;
        }
        return Game._findWinner(playerCount_, round_);
    }

    function _assertValidPlayer(IPlayer player) private view {
        assert(_playerByIdx[getIndexFromPlayer(player)] == player);
    }
}

contract NoopPlayer is IPlayer {
    uint8 public PLAYER_IDX;
    uint8 immutable PLAYER_COUNT;

    constructor(uint8 playerIdx, uint8 playerCount) {
        PLAYER_IDX = playerIdx;
        PLAYER_COUNT = playerCount;
        emit PlayerCreated(address(this), playerIdx, playerCount);
    }

    function turn(uint8 builderIdx) external virtual {
        emit Turning(Game(msg.sender).round(), PLAYER_IDX, builderIdx);
    }

    function buildBlock() external virtual returns (uint256) {
        emit Building(Game(msg.sender).round(), PLAYER_IDX);
        return 0;
    }
}

contract DonatingPlayer is NoopPlayer {
    constructor(uint8 playerIdx, uint8 playerCount) NoopPlayer(playerIdx, playerCount) {}

    function turn(uint8) external override {
        Game game = Game(msg.sender);
        uint8 assetCount = game.assetCount();
        for (uint8 assetIdx = 1; assetIdx < assetCount; ++assetIdx) {
            // Always donate to last player.
            game.transfer(
                PLAYER_COUNT - 1,
                assetIdx,
                game.balanceOf(PLAYER_IDX, assetIdx)
            );
        }
    }
}

contract RevertingPlayer is NoopPlayer {
    constructor(uint8 playerIdx, uint8 playerCount) NoopPlayer(playerIdx, playerCount) {}
    function turn(uint8) external override pure { T.throwInvalid(); }
    function buildBlock() external override pure returns (uint256) { T.throwInvalid(); }
}

contract BuilderPlayer is NoopPlayer {
    struct AssetOwed {
        IPlayer player;
        uint8 assetIdx;
        uint256 amount;
    }

    struct PreparedCall {
        address target;
        bytes callData;
    }

    IPlayer public ignoredPlayer;
    uint256 public bid;
    RevertMode public revertOnBuild;
    AssetOwed[] public mints;
    AssetOwed[] public burns;
    PreparedCall public preparedCall;

    constructor(uint8 playerIdx, uint8 playerCount) NoopPlayer(playerIdx, playerCount) {}

    function turn(uint8 builderIdx) external override {
        TestGame game = TestGame(msg.sender);
        emit Turning(game.round(), PLAYER_IDX, builderIdx);
        for (uint256 i; i < mints.length; ++i) {
            AssetOwed memory ao = mints[i];
            game.mintAssetTo(ao.player, ao.assetIdx, ao.amount);
        }
        for (uint256 i; i < burns.length; ++i) {
            AssetOwed memory ao = burns[i];
            game.burnAssetFrom(ao.player, ao.assetIdx, ao.amount);
        }
        if (preparedCall.target != address(0)) {
            (bool s, bytes memory r) = preparedCall.target.call(preparedCall.callData);
            if (!s) r.rawRevert();
        }
    }

    function buildBlock() external override returns (uint256) {
        TestGame game = TestGame(msg.sender);
        if (revertOnBuild == RevertMode.Revert) revert TestError();
        else if (revertOnBuild == RevertMode.Invalid) T.throwInvalid();
        emit Building(game.round(), PLAYER_IDX);
        for (uint8 i; i < PLAYER_COUNT; ++i) {
            if (ignoredPlayer != NULL_PLAYER && getIndexFromPlayer(ignoredPlayer) == i) continue;
            game.grantTurn(i);
        }
        return bid;
    }

    function setCallOnTurn(address target, bytes calldata cd) external {
        preparedCall = PreparedCall(target, cd);
    }

    function addMintOnTurn(IPlayer player, uint8 assetIdx, uint256 amount) external {
        mints.push(AssetOwed(player, assetIdx, amount));
    }

    function addBurnOnTurn(IPlayer player, uint8 assetIdx, uint256 amount) external {
        burns.push(AssetOwed(player, assetIdx, amount));
    }
   
    function setBid(uint256 bid_) external {
        bid = bid_;
    }

    function setRevertOnBuild(RevertMode mode) external {
        revertOnBuild = mode;
    }

    function ignorePlayer(IPlayer player) external {
        ignoredPlayer = player;
    }
}