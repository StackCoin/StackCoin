# build
FROM crystallang/crystal:0.35.1-alpine-build as build

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
RUN crystal build src/stackcoin.cr --release --static -o stackcoin

# prod
FROM alpine:3
RUN apk add --update --no-cache --force-overwrite \
        ttf-opensans \
        gnuplot

WORKDIR /app
COPY ./.env.dist /app/.env
COPY --from=build /build/stackcoin /app/stackcoin

RUN mkdir ./src
COPY ./src/gnuplot ./src/gnuplot

EXPOSE 3000
CMD ["/app/stackcoin"]
