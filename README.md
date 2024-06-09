# Searchers of Nottingham

![illustration](static/illustration.png)

[Searchers of Nottingham](https://dragonfly-xyz.github.io/nottingham-frontend) is an [MEV](https://chain.link/education-hub/maximal-extractable-value-mev)-themed game built on the [Ethereum](https://ethereum.org) Virtual Machine. Players submit compiled smart contracts which represent Merchants at a medieval fair trying to stock their stall with goods (tokens). Merchants face each other in multiple small games. Each round Merchants will try to exchange their gold and goods at the Market (a constant product [AMM](https://chain.link/education-hub/what-is-an-automated-market-maker-amm)). But a Merchant can also choose to bid gold to become the "Sheriff" for that round. The Sheriff chooses the order in which all trades are made and can also make their own trades at will. The first Merchant to acquire the maximum amount of any single good will win!

## Project Setup
Assuming you already have [foundry](https://getfoundry.sh) configured, clone the repo, enter the project folder, then just

```bash
# Install dependencies.
forge install
# Build the project.
forge build
```

## Game Concepts

> ℹ️ You can find the core logic for the game inside [Game.sol](./src/game/Game.sol).

### Game Setup

Each match happens in a fresh instance of the `Game` contract.

1. The `Game` contract will deploy each of the player bytecodes passed in and assign them player indexes in the same order. Players are identified by these (0-based) indices, not their address. Players will not know the address of other players in production.
2. An N-dimensional constant-product [AMM](./src/game/Markets.sol) will be initialized with `N` assets/tokens, where `N` is equal to the number of players in the game. Assets are 18-decimal tokens identified by their (0-based) asset index. Asset `0` is equivalent to the "gold" asset and `1+` are designanted as "goods." This means that there is always one less good than there are players.

> ℹ️ Contest tournaments matches always consist of **4** players.

### Game Rounds

For every round the following happens:

1. Each player is resupplied, being minted `1` units (`1e18`) of every goods token and only `1` *wei* of gold.
2. All players participate in a blind auction for the privilege of building the block for the round.
3. If a player wins the block auction, that player builds the block, settling all bundles and getting their bid burned.
4. If no player wins the block auction, no bundles are settled.
5. If we've played the maximum number of rounds (`32`) or a player is found to have `64` units (`64e18`) of *any* goods token, the game ends.

When the game ends, players are sorted by their maximum balance of any goods token. This is the final ranking for the match.

### Player Contracts

Players are smart contracts that expose [two callback functions](./src/game/IPlayer.sol):

* `createBundle(uint8 builderIdx) -> PlayerBundle bundle`
    * Returns a `PlayerBundle` for the round, which consists of a sequence of swaps that must be executed by the block builder identified by `builderIdx`.
* `buildBlock(PlayerBundle[] bundles) -> uint256 bid`
    * Receives all bundles created by every player, ordered by player index.
    * Must settle (via `Game.settleBundle()`) *ALL but their own* bundles, but in any order.
    * Can directly call swap functions on the `Game` instance (`sell()` or `buy()`).
    * Returns the player's bid (in gold) to build this block. This gold will be burned if they win the block auction.

## Developing and Testing Players

The [`IGame`](./src/game/IGame.sol) interface exposes all functions on the `Game` instance available to players. You should take some time to quickly review it.

The project comes with some [example player contracts](./script/players/). None are particularly sophisticated but will demonstrate typical player behaviors. You can choose to create new contracts in the `players` folder and extend the examples to get started quickly.

### Local Matches
The project comes with a foundry [script](./script/Match.sol) for running matches locally so you can see how well your bot performs against others. Matches can be held against 2 or more player contracts. Note that production tournaments are always conducted with 4 players.

For example, you can run a match against the included example players [`GreedyBuyer`](./script/players/GreedyBuyer.sol) and [`CheapBuyer`](./script/players/CheapBuyer.sol) with the following command:

```bash
forge script Match --sig 'runMatch(string[])' '["GreedyBuyer.sol", "CheapBuyer.sol"]'
```

`runMatch()` assigns players the same player indexes in the same order that player names are passed in. The performance of some of the example players can be biased by their order in a match. You can instead use `runShuffledMatch()` to assign players a random index each run:

```bash
forge script Match --sig 'runShuffledMatch(string[])' '["GreedyBuyer.sol", "CheapBuyer.sol"]'
```

If successful, the output of either command will:
- For each round:
	- Print each player's bid, ending balances, and change from last round.
    - Prefix the player that built the block with `(B)`.
	- Print the swaps that occured in that round, in order.
- At the end of game, print the final score (max non-gold balance) for each player.

```bash
# ...
  Round 26:
  	   SimpleBuyer [0] (bid 🪙 0.0):
			🪙 0.0 (+0.0)
			🍅 64.7681 (+3.6227)
  	   TheCuban [3] (bid 🪙 0.462):
			🪙 0.840 (+0.7)
			🍅 1.9701 (+0.9801)
			🥖 1.9701 (+0.9801)
			🐟️ 62.1590 (+1.0)
  	   GreedyBuyer [1] (bid 🪙 0.119):
			🪙 0.83 (+0.83)
			🍅 22.7657 (+0.7700)
			🥖 22.7657 (+0.7700)
			🐟️ 26.0 (+1.0)
  	(B) CheapFrontRunner [2] (bid 🪙 0.685):
			🪙 0.1394 (+0.0)
			🍅 0.1994 (-3.0)
			🥖 2.6864 (-52.8701)
			🐟️ 25.6553 (+23.6235)
  
	======ROUND ACTIVITY======

  	(B) CheapFrontRunner sold:
			🍅 0.2099 -> 🪙 0.58
			🍅 3.7900 -> 🐟️ 3.4115
			🥖 2.8278 -> 🪙 0.626
			🥖 51.423 -> 🐟️ 19.2119
  	    SimpleBuyer sold:
			🥖 1.0 -> 🍅 0.4492
			🐟️ 1.0 -> 🍅 2.1734
  	    GreedyBuyer sold:
			🍅 0.2299 -> 🪙 0.58
			🥖 0.2299 -> 🪙 0.24
  	    TheCuban sold:
			🍅 0.199 -> 🪙 0.5
			🥖 0.199 -> 🪙 0.2
  
🏁 Game ended after 26 rounds:
  	🏆️ SimpleBuyer [0]: 🍅 64.7681 (1)
  	🥈 TheCuban [3]: 🐟️ 62.1590 (3)
  	🥉 GreedyBuyer [1]: 🐟️ 26.0 (3)
  	🥉 CheapFrontRunner [2]: 🐟️ 25.6553 (3)
```

If you want to see more detail of what went on during a match, you can run the script with full traces on by passing in the `-vvvv` flag. Be warned, this will be a lot of output and can be difficult to read because of how the game logic calls player callbacks repeatedly to simulate them.

>⚠️ Local matches use the foundry scripting engine but the actual tournaments use an isolated, vanilla, Dencun-hardfork environment, so any foundry cheatcodes used by your player contract will fail in production. You should also not count on the `Game` contract being at the same address.