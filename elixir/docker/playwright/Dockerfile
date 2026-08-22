FROM node:22-bookworm

ARG PLAYWRIGHT_VERSION=1.63.0-alpha-2026-08-05
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

RUN npm install --global "playwright@${PLAYWRIGHT_VERSION}" \
    && playwright install --with-deps chromium \
    && chmod -R a+rX /ms-playwright

USER node

CMD ["playwright", "run-server", "--host", "0.0.0.0", "--port", "3000", "--max-clients", "20"]
