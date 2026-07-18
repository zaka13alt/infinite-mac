# ==============================================================================
# STAGE 1: Emscripten Compiler Environment (Compiles the C++ Emulator Core)
# ==============================================================================
FROM emscripten/emsdk:3.1.53 AS emulator-builder

RUN apt-get update && apt-get install -y \
    build-essential autoconf automake pkg-config libtool \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

WORKDIR /src/packages/emulators/macemu/SheepShaver/src/Unix
RUN emconfigure ./autogen.sh --enable-addressing=real --without-mon --without-esd --without-gtk
RUN chmod +x ./_emconfigure.sh && ./_emconfigure.sh && emmake make -j$(nproc)


# ==============================================================================
# STAGE 2: Node.js Backend Proxy Builder (Compiles the Server-Side Slirp Layer)
# ==============================================================================
FROM node:18-bullseye AS proxy-builder

RUN apt-get update && apt-get install -y \
    build-essential python3 libslirp-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . .

WORKDIR /app/packages/basilisk-net
RUN npm install && npm run build


# ==============================================================================
# STAGE 3: Final Production Runner (Serves Static Web Content + Runs Net Proxy)
# ==============================================================================
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install NGINX web server and Node runtime ecosystem
RUN apt-get update && apt-get install -y \
    nginx \
    curl \
    libslirp0 \
    && curl -fsSL https://nodesource.com | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 1. Bring over the compiled proxy backend application from Stage 2
COPY --from=proxy-builder /app/packages/basilisk-net /app/basilisk-net

# 2. Build deployment target directories for static file delivery
RUN mkdir -p /var/www/html/emulator

# 3. Pull the WebAssembly distribution artifacts out from Stage 1
COPY --from=emulator-builder /src/packages/emulators/macemu/SheepShaver/src/Unix/SheepShaver.wasm /var/www/html/emulator/
COPY --from=emulator-builder /src/packages/emulators/macemu/SheepShaver/src/Unix/SheepShaver.js /var/www/html/emulator/

# 4. Pull down the frontend user interface code files
COPY --from=emulator-builder /src/packages/worker /var/www/html/

# 5. Inject NGINX config featuring required SharedArrayBuffer security headers (COOP/COEP)
RUN echo '\
server {\n\
    listen 80;\n\
    server_name localhost;\n\
    root /var/www/html;\n\
    index index.html;\n\
\n\
    location / {\n\
        try_files $uri $uri/ =404;\n\
        add_header Cross-Origin-Opener-Policy "same-origin";\n\
        add_header Cross-Origin-Embedder-Policy "require-corp";\n\
    }\n\
\n\
    location ~* \.wasm$ {\n\
        types { application/wasm wasm; }\n\
        add_header Cross-Origin-Opener-Policy "same-origin";\n\
        add_header Cross-Origin-Embedder-Policy "require-corp";\n\
    }\n\
}\n' > /etc/nginx/sites-available/default

# Expose NGINX HTTP (80) and Web proxy WebSocket port (8081)
EXPOSE 80 8081

# Fire up web servers simultaneously
CMD service nginx start && cd /app/basilisk-net && npm start
