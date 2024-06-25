> 🚨 This repo will be updated regularly for bug fixes, if game balance is tweaked, and to add top agents from seasons. Try to pull every now and then.

# Searchers of Nottingham

![illustration](static/illustration.png)

[Searchers of Nottingham](https://dragonfly-xyz.github.io/nottingham-frontend) is an [MEV](https://chain.link/education-hub/maximal-extractable-value-mev)-themed multiplayer game built on the [Ethereum](https://ethereum.org) Virtual Machine. Players submit compiled smart contracts (agents) which represent Merchants at a medieval fair trying to stock their stall with goods (tokens). Merchants face each other in multiple small games. Each round Merchants will try to exchange their gold and goods at the Market (a constant product [AMM](https://chain.link/education-hub/what-is-an-automated-market-maker-amm)). But a Merchant can also choose to bid gold to become the "Sheriff" for that round. The Sheriff chooses the order in which all trades are made and can also make their own trades at will. The first Merchant to acquire the maximum amount of any single good will win!

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

1. The `Game` contract will deploy each of the agent bytecodes passed in and assign them player indexes in the same order. Agents are identified by these (0-based) indices, not their address. Agents will not know the address of other agents.
2. An N-dimensional constant-product [AMM](./src/game/Markets.sol) will be initialized with `N` assets/tokens, where `N` is equal to the number of agents in the game. Assets are 18-decimal tokens identified by their (0-based) asset index. Asset `0` is equivalent to the "gold" asset and `1+` are designanted as "goods." This means that there is always one less good than there are players.

> ℹ️ Contest tournament matches always consist of **4** agents.

### Game Rounds

For every round the following happens:

1. Each agent is resupplied, being minted `1` units (`1e18`) of every goods token and only `1` *wei* of gold.
2. All agents participate in a blind auction for the privilege of building the block for the round.
3. If an agent wins the block auction, that agent builds the block, settling all bundles and getting their bid burned.
4. If no agent wins the block auction, no bundles are settled.
5. Each reserve of goods token in the market (i.e., not held by players) will have ~6% burned. (*🌟 New for season 3*)
6. If we've played the maximum number of rounds (`32`) or an agent is found to have `64` units (`64e18`) of *any* goods token, the game ends.

When the game ends, agents are sorted by their maximum balance of any goods token. This is the final ranking for the match.

### Agent Contracts

Agents are smart contracts that expose [two callback functions](./src/game/IPlayer.sol):

* `createBundle(uint8 builderIdx) -> PlayerBundle bundle`
    * Returns a `PlayerBundle` for the round, which consists of a sequence of swaps that must be executed by the block builder identified by `builderIdx`.
	* Each player bundle is settled atomically (the swaps cannot be broken up).
	* Empty swaps will be ignored.
	* If ANY swap in your bundle fails due to insufficient balance, the entire bundle fails, so beware!
* `buildBlock(PlayerBundle[] bundles) -> uint256 bid`
    * Receives all bundles created by every agent, ordered by player index.
    * Must settle (via `Game.settleBundle()`) ALL OTHER player bundles, in *any* order. Settiling the builder's own bundle is optional.
    * Can directly call swap functions on the `Game` instance (`sell()` or `buy()`) at any time, including between settling other player bundles.
    * Returns the agent's bid (in gold) to build this block. This gold will be burned if they win the block auction.

## Developing and Testing Agents

The [`IGame`](./src/game/IGame.sol) interface exposes all functions on the `Game` instance available to agents. You should take some time to quickly review it.

The project comes with some [example agent contracts](./script/agents/). None are particularly sophisticated but will demonstrate typical agent behaviors. You can choose to create new contracts in the `agents` folder and extend the examples to get started quickly.

### Local Matches
The project comes with a foundry [script](./script/Match.sol) for running matches locally so you can see how well your bot performs against others. Matches can be held against 2 or more agent contracts. Note that production tournaments are always conducted with 4 agents.

For example, you can run a match against the included example agents [`GreedyBuyer`](./script/agents/GreedyBuyer.sol), [`CheapBuyer`](./script/agents/CheapBuyer.sol), and [`CheapFrontRunner`](./script/agents/CheapFrontRunner.sol) with the following command:

```bash
forge script Match --sig 'runMatch(string[])' '["GreedyBuyer", "CheapBuyer", "CheapFrontRunner"]'
```

`runMatch()` assigns agents the same player indexes in the same order that agent names are passed in. The performance of some of the example agents can be biased by their order in a match. You can instead use `runShuffledMatch()` to assign agents a random index each run:

```bash
forge script Match --sig 'runShuffledMatch(string[])' '["GreedyBuyer", "CheapBuyer", "CheapFrontRunner"]'
```

If successful, the output of either command will:
- For each round:
	- Print each agent's bid, ending balances, and change from last round.
    - Prefix the agent that built the block with `(B)`.
	- If the agent's name is in red, one of their callbacks failed.
	- Print the swaps that occured in that round, in order.
- At the end of game, print the final score (max non-gold balance) for each agent.

If an agent's name shows up in red it means it reverted during one of its callbacks.

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

If you want to see more detail of what went on during a match, you can run the script with full traces on by passing in the `-vvvv` flag. Be warned, this will be a lot of output and can be difficult to read because of how the game logic calls agent callbacks repeatedly to simulate them.

>⚠️ Local matches use the foundry scripting engine but the actual tournaments use an isolated, vanilla, Dencun-hardfork environment, so any foundry cheatcodes used by your agent contract will fail in production. You should also not count on the `Game` contract being at the same address.