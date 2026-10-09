FROM ruby:3.4-slim

ENV RAILS_ENV=production \
    BUNDLE_WITHOUT="development:test" \
    BUNDLE_PATH="/bundle" \
    BUNDLE_DEPLOYMENT="1" \
    LANG=C.UTF-8

# build-essential + libpq-dev: wymagane do zbudowania gema `pg`.
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends \
      build-essential libpq-dev curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Warstwa zależności (cache budowania): najpierw Gemfile.lock, potem kod.
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs "$(nproc)" --retry 3

COPY . .

RUN mkdir -p tmp/pids tmp/cache tmp/sockets log

COPY entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

EXPOSE 3000
ENTRYPOINT ["entrypoint"]
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]