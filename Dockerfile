FROM ruby:4.0.3-slim-bookworm

ENV APP_HOME=/app \
    DEBIAN_FRONTEND=noninteractive \
    BUNDLE_WITHOUT="development:test" \
    CHROME_BIN=/usr/bin/chromium \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    PUPPETEER_SKIP_DOWNLOAD=true \
    GROVER_NO_SANDBOX=true \
    WKHTMLTOPDF_BIN=/usr/bin/wkhtmltopdf

WORKDIR ${APP_HOME}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      chromium \
      fonts-noto-cjk \
      fonts-noto-color-emoji \
      nodejs \
      npm \
      wkhtmltopdf \
    && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock package.json package-lock.json ./
RUN bundle install \
    && npm ci

COPY . .

CMD ["bundle", "exec", "ruby", "bin/run_benchmark_report"]
