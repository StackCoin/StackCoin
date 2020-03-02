# build
FROM crystallang/crystal:0.33.0-alpine-build as build

RUN apk add --update --no-cache --force-overwrite \
        sqlite-static \
        sqlite-dev

WORKDIR /build

COPY shard.yml /build/
COPY shard.lock /build/
RUN mkdir src
COPY ./src /build/src

RUN mkdir data
RUN echo "" > data/stackcoin.db

RUN shards
RUN crystal build src/bot.cr --release --static -o bot

# prod
FROM alpine:3

WORKDIR /app
COPY ./.env.dist /app/.env
COPY --from=build /build/bot /app/bot

EXPOSE 3000
CMD ["/app/bot"]
