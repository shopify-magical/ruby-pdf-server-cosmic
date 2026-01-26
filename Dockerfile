FROM ruby:2.6-slim

# Install system dependencies
RUN apt-get update -qq && \
    apt-get install -y build-essential curl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy gem files
COPY Gemfile ./

# Install ruby gems
RUN bundle install --without development

# Copy application code
COPY . .

# Expose port
EXPOSE 4567

# Start the application
CMD ["bundle", "exec", "ruby", "app.rb", "-o", "0.0.0.0"]