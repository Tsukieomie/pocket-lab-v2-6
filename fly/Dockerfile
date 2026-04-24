FROM debian:12-slim

# Copy custom bore binary (control port patched to 2222)
COPY bore-custom-2222 /usr/local/bin/bore
RUN chmod +x /usr/local/bin/bore

# Control port 2222, tunnel port range 40000-40100
EXPOSE 2222
EXPOSE 40000-40100

ENV BORE_SECRET=""

CMD ["sh", "-c", "bore server --secret \"$BORE_SECRET\" --min-port 40000 --max-port 40100"]
