# Builds clawtank-mcp in a Linux container for MCP registries (such as Glama) that start servers
# to introspect them. In a container it answers initialize and tools/list; tool calls need
# ClawTank running on a Mac with the Agent API on (see docs/agent-api.md).
#
# Build from the repository root: docker build -f core/clawtank-mcp/Dockerfile .
FROM rust:1-slim AS build
WORKDIR /src
COPY core ./core
RUN cd core && cargo build --release --locked -p clawtank-mcp

FROM debian:stable-slim
COPY --from=build /src/core/target/release/clawtank-mcp /usr/local/bin/clawtank-mcp
ENTRYPOINT ["clawtank-mcp"]
