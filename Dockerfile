FROM node:18-slim AS dependencies

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:18-slim AS production

ENV NODE_ENV=production
WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        wkhtmltopdf \
        fonts-dejavu \
        fonts-liberation \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

COPY --from=dependencies /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
COPY templates ./templates

CMD ["node", "src/index.js"]