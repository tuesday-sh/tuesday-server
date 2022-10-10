FROM ruby:2.7.6-alpine
RUN apk update \
  && apk upgrade \
  && apk add --update --no-cache \
  build-base curl-dev git postgresql-dev \
  yaml-dev zlib-dev tzdata nodejs yarn
WORKDIR /usr/src/app
ENV RAILS_ENV=development
ENV NODE_ENV=development
COPY Gemfile* ./
COPY vendor ./vendor
RUN gem install bundler -v 2.3.14
RUN bundle install && bundle package --no-install --cache-path=/usr/src/app/vendor/cache
RUN yarn install
COPY . .
# RUN bin/rails assets:precompile
EXPOSE 3000
CMD ["rails", "server", "-b", "0.0.0.0"]