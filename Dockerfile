FROM alpine:3.20
RUN apk update \
  && apk upgrade \
  && apk add --update --no-cache \
  build-base curl-dev git postgresql-dev \
  yaml-dev zlib-dev tzdata gcompat nodejs
# when alpine replaces the ruby version in this repo it will break if the version
# does not match the ruby version in Gemfile
RUN apk add ruby-dev --no-cache
WORKDIR /usr/src/app
ENV RAILS_ENV=development
ENV NODE_ENV=development
COPY Gemfile* ./
COPY vendor ./vendor
RUN gem install bundler -v 2.5.20
RUN bundle config --global silence_root_warning 1
RUN bundle install && bundle package --no-install --cache-path=/usr/src/app/vendor/cache
COPY . .
# RUN bin/rails assets:precompile
EXPOSE 3000
CMD ["rails", "server", "-b", "0.0.0.0"]
