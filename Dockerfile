
FROM nginx:alpine

LABEL maintainer="AI DevOps Agent" \
      name="static-website" \
      description="Static HTML website served by nginx" \
      version="1.0.0"

RUN apk add --no-cache curl \
    && adduser -S appuser \
    && mkdir -p /usr/share/nginx/html /tmp/nginx \
    && chown -R appuser:root /usr/share/nginx/html /var/cache/nginx /var/run /tmp/nginx \
    && chmod -R g+w /var/cache/nginx /var/run

WORKDIR /usr/share/nginx/html

COPY css/ ./css/
COPY webfonts/ ./webfonts/
COPY imgs/ ./imgs/
COPY index.html plans.html projects.html courses.html files.html settings.html profile.html friends.html ./

RUN echo "OK" > /usr/share/nginx/html/health

# Configure nginx to use writable paths when running as non-root
RUN sed -i 's|pid /run/nginx.pid;|pid /tmp/nginx/nginx.pid;|' /etc/nginx/nginx.conf \
    && sed -i 's|/var/run/nginx.pid|/tmp/nginx/nginx.pid|' /etc/nginx/nginx.conf \
    && sed -i 's|user nginx;|# user nginx;|' /etc/nginx/nginx.conf

USER appuser

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl --fail http://localhost:80/health || exit 1

CMD ["nginx", "-g", "daemon off;"]

