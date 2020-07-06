[![docs](https://img.shields.io/badge/docs-latest-green.svg?style=flat-square)](https://jackharrhy.github.io/StackCoin/)

![](https://img.shields.io/badge/Docs-latest-green)

![](https://github.com/jackharrhy/StackCoin/workflows/Deploy%20to%20Dockerhub/badge.svg)

# StackCoin

![StackCoin coin of Stack on coin](https://i.imgur.com/ou12BG6.png)

a discord pseudo currency, written using (discordcr)[https://github.com/discordcr/discordcr]

![Creator of StackCoin running commands in a private guild, showing the different usages of the bot, such as collecting a daily dole, sending StackCoin to other users, checking a graph of data showing their balance over time, and the leaderboard of the current highest balances of the top 5 accounts](https://i.imgur.com/alF7EcU.png)

---

## Requirements:

- crystal 0.35+
- sqlite3, development variant

## Running:

```sh
cp .env.dist .env # then populate .env

shards # installs deps

crystal run src/stackcoin.cr # runs bot!
```

---

```txt
[11:09] stack: i hate it
```
