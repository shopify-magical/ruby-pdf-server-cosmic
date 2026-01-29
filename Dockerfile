# Cosmic Deployment Protocol: Ruby++ PDF Server
FROM ruby:2.6.10-slim

# Install system dependencies for PDF generation and native gems
RUN apt-get update -qq && apt-get install -y \
    build-essential \
    libpq-dev \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# Set high-performance environment variables
ENV BUNDLE_PATH=/usr/local/bundle
ENV GEM_HOME=/usr/local/bundle
ENV PATH="/usr/local/bundle/bin:${PATH}"
ENV APP_HOME /app
ENV RACK_ENV production

WORKDIR $APP_HOME

# Install dependencies first for layer caching
COPY Gemfile* ./
RUN gem install bundler:2.2.3 && \
    bundle config set --local without 'development' && \
    bundle install --jobs 4 --retry 3

# Copy application source
COPY . .

# Expose the cosmic port
EXPOSE 4567

# Launch the engine
CMD ["bundle", "exec", "ruby", "app.rb", "-o", "0.0.0.0"]
