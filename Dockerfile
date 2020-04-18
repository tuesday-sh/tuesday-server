FROM ruby:2.6.6-alpine
RUN apk update \
  && apk upgrade \
  && apk add --update --no-cache \
  build-base curl-dev git postgresql-dev \
  yaml-dev zlib-dev tzdata
WORKDIR /usr/src/app
ENV RAILS_ENV=development
ENV NODE_ENV=development
#COPY Gemfile* ./
COPY . .
RUN gem install bundler -v 1.17.3
RUN bundle install && bundle package --cache-path=/usr/src/app/vendor/cache

# RUN bin/rails assets:precompile
EXPOSE 3000
# CMD ["rails", "server", "-b", "0.0.0.0"]