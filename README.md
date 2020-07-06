[![Documentation badge](https://img.shields.io/badge/docs-latest-green.svg?style=flat-square)](https://jackharrhy.github.io/StackCoin/) ![Deploy to Dockerhub badge](https://github.com/jackharrhy/StackCoin/workflows/Deploy%20to%20Dockerhub/badge.svg)

# StackCoin

![StackCoin coin of Stack on coin](https://i.imgur.com/ou12BG6.png)

a discord pseudo currency, written using [discordcr](https://github.com/discordcr/discordcr)

![Creator of StackCoin running commands in a private guild, showing the different usages of the bot, such as collecting a daily dole, sending StackCoin to other users, checking a graph of data showing their balance over time, and the leaderboard of the current highest balances of the top 5 accounts](https://i.imgur.com/alF7EcU.png)

---

## Requirements:

- crystal 0.35+
- sqlite3, development variant

## Running:

```sh
cp .env.dist .env # then populate .env

shards # install deps

crystal run src/stackcoin.cr # run bot!
```

---

## Contributors:

- [jackharrhy](https://github.com/jackharrhy) - creator, maker of most
- [z64](https://github.com/z64) - made small typo fix, and fixed the specs running, but also maintainer of discordcr, and wrote code that has influenced this bot heavily
- [Mudkip](https://github.com/Mudkip) - wrote the `s!unban` command, since he was banned for a short period of time while the feature did not exist :)
- [SteveParson](https://github.com/SteveParson) - wrote the first iteration of the `s!leaderboard` command
- [ranguli](https://github.com/ranguli) - removed the header in the readme as a meme

---

```txt
[11:09] stack: i hate it
```
