FROM ruby:2.6.2-alpine
RUN apk update \
  && apk upgrade \
  && apk add --update --no-cache \
  build-base curl-dev git postgresql-dev \
  yaml-dev zlib-dev tzdata
WORKDIR /usr/src/app
ENV RAILS_ENV=development
ENV NODE_ENV=development
COPY Gemfile* ./
RUN bundle install
COPY . .
# RUN bin/rails assets:precompile
EXPOSE 3000
CMD ["rails", "server", "-b", "0.0.0.0"]