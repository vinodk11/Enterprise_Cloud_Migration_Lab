# StreamFlix Backend API - Dockerfile
FROM node:18-slim

# Create app directory
WORKDIR /app

# Install production dependencies
COPY package*.json ./
RUN npm ci --omit=dev

# Bundle app source
COPY . .

# Expose API listening port
EXPOSE 5000

# Set environment defaults
ENV PORT=5000 \
    NODE_ENV=production

# Health check endpoint
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "require('http').get('http://localhost:5000/api/health', (r) => {if (r.statusCode !== 200) process.exit(1);});"

# Run as non-root node user for container security
USER node

# Start the Express server
CMD ["node", "server.js"]
