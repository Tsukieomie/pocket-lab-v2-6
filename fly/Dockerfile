FROM debian:12-slim

# Install bore
RUN apt-get update && apt-get install -y curl ca-certificates && \
    curl -sL https://github.com/ekzhang/bore/releases/download/v0.6.0/bore-v0.6.0-x86_64-unknown-linux-musl.tar.gz \
    | tar xz -C /usr/local/bin/ && \
    chmod +x /usr/local/bin/bore && \
    apt-get remove -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

# Bore control port
EXPOSE 7835
# Tunnel port range
EXPOSE 40000-40100

# BORE_SECRET must be set as a Fly secret
ENV BORE_SECRET=""

CMD ["sh", "-c", "bore server --secret \"$BORE_SECRET\" --min-port 40000 --max-port 40100"]
