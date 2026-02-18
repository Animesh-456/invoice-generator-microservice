FROM node:18-slim

# Install wkhtmltopdf and dependencies in one layer
RUN apt-get update && apt-get install -y \
    wkhtmltopdf \
    fonts-dejavu \
    fonts-liberation \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

WORKDIR /app

# Copy package files
COPY package*.json ./

# Install dependencies
RUN npm ci --only=production

# Copy source code
COPY . .

CMD ["node", "src/index.js"]