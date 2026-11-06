# syntax=docker/dockerfile:1
# Local development image for tuesday-server using Chainguard Wolfi (glibc, zero-CVE base)
FROM cgr.dev/chainguard/wolfi-base:latest

RUN apk update && apk add --no-cache \
    build-base \
    curl-dev \
    git \
    ruby-3.3 \
    ruby-3.3-dev \
    postgresql-dev \
    sqlite-dev \
    yaml-dev \
    zlib-dev \
    libffi-dev \
    openssl-dev \
    tzdata \
    nodejs

WORKDIR /usr/src/app
ENV RAILS_ENV=development \
    NODE_ENV=development

COPY Gemfile* ./
COPY vendor ./vendor
RUN gem install bundler -v 2.5.20 --no-document && \
    bundle config --global silence_root_warning 1 && \
    bundle install && \
    bundle package --no-install --cache-path=/usr/src/app/vendor/cache

COPY . .

EXPOSE 3000
CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0"]
