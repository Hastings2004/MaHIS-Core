# MaHIS-Core API image for the two-way sync deployment (central and sites).
# Build context: the MaHIS-Core root.
FROM ruby:3.2.2-slim-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential default-libmysqlclient-dev default-mysql-client git curl \
      libyaml-dev pkg-config tzdata shared-mime-info \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV RAILS_ENV=development \
    BUNDLE_JOBS=4 \
    TZ=Africa/Blantyre

COPY Gemfile Gemfile.lock ./
# Downloaded gems are kept in a build cache and each download is retried, so
# a dropped connection costs a retry, not a full reinstall.
RUN --mount=type=cache,target=/usr/local/bundle/cache,sharing=locked \
    gem install bundler -v 2.4.10 && bundle install --retry 5

COPY . .
RUN chmod +x prototype/site_sync/docker/*.sh

EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
