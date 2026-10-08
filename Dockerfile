FROM nginx:alpine

LABEL maintainer="AI DevOps Agent" \
      name="static-website" \
      description="Static HTML website served by nginx" \
      version="1.0.0"

# Install curl for healthcheck and create non-root user
RUN apk add --no-cache curl \
    && adduser -S appuser \
    && mkdir -p /usr/share/nginx/html \
    && chown -R appuser:root /usr/share/nginx/html /var/cache/nginx /var/run

WORKDIR /usr/share/nginx/html

# Copy static assets first (grouped for layer caching)
COPY css/ ./css/
COPY webfonts/ ./webfonts/
COPY imgs/ ./imgs/

# Copy HTML source files
COPY index.html plans.html projects.html courses.html files.html settings.html profile.html friends.html ./

# Add health endpoint
RUN echo "OK" > /usr/share/nginx/html/health

USER root

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 CMD curl --fail http://localhost:80/health || exit 1

CMD ["nginx", "-g", "daemon off;"]
