# Marveen thin runtime image.
#
# Philosophy: this image carries ONLY the runtime (Node + tmux + the claude CLI
# + build toolchain). It does NOT bake in the Marveen source. The code and all
# state (store/, agents/, .env, the ~/.claude "dotcloud") live OUTSIDE the image,
# bind-mounted from the host at /app -- so you update Marveen on the host
# (git pull / update) and just restart the container; no image rebuild.
#
# The one thing that MUST be container-built is node_modules: better-sqlite3 is a
# native module compiled against this image's Node/glibc. Keep it on the
# dedicated `node_modules` volume (see docker-compose.yml) so a host-built
# node_modules never leaks in and breaks the binding.
FROM node:22-bookworm-slim

# Runtime + native-build deps:
#  - tmux           : agents run as interactive `claude` processes in tmux panes
#  - build-essential, python3 : node-gyp toolchain for better-sqlite3
#  - git            : update.sh / version reporting
#  - procps         : `ps` for the agent liveness checks
#  - ca-certificates: TLS for the channel + API calls
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tmux git build-essential python3 procps ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# The Claude Code CLI (the agent runtime). Pinning to a version is possible;
# left unpinned so a rebuild tracks latest -- pin here if your org needs it.
RUN npm install -g @anthropic-ai/claude-code

WORKDIR /app

# claude refuses --dangerously-skip-permissions as uid 0; the whole stack runs
# fine in a container with this escape hatch (mirrors scripts/start.sh).
ENV IS_SANDBOX=1 \
    HOME=/app/store/home \
    NODE_ENV=production \
    WEB_PORT=3420

EXPOSE 3420

# The entrypoint itself lives in the bind-mounted source, so it is updatable
# from the host like everything else -- the image stays truly thin.
ENTRYPOINT ["bash", "/app/docker/entrypoint.sh"]
