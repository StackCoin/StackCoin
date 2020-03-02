FROM crystallang/crystal:0.33.0-alpine-build as crystalbuilder
RUN apk add --update --no-cache --force-overwrite \
        sqlite-static \
        sqlite-dev

WORKDIR /src

COPY shard.yml /src/
COPY shard.lock /src/
RUN mkdir src
COPY ./src /src/src
COPY .env.dist /src/.env

RUN mkdir data
RUN echo "" > data/stackcoin.db

RUN shards
RUN crystal build src/bot.cr --release --static -o bot

# production environment

FROM nginx:mainline-alpine

RUN apk add --no-cache --update --force-overwrite \
	bash \
	supervisor

RUN rm -rf /tmp/* /var/cache/apk/*

ADD ./supervisord.conf /etc/

WORKDIR /app
COPY --from=crystalbuilder /src/bot /app/bot
COPY --from=crystalbuilder /src/data /app/data

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
