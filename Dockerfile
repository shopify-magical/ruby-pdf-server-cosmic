FROM ruby:3.0-slim

# Install system dependencies
RUN apt-get update -qq && \
    apt-get install -y build-essential && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy gem files
COPY Gemfile Gemfile.lock ./

# Install ruby gems
RUN bundle install --deployment --without development

# Copy application code
COPY . .

# Create non-root user
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser /app
USER appuser

# Expose port
EXPOSE 4567

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:4567/health || exit 1

# Start the application
CMD ["ruby", "app.rb"]