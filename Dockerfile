# Build a self-contained OTP release. Zero external Hex deps, so the build is fast.
FROM elixir:1.18-otp-27-alpine AS build

ENV MIX_ENV=prod
WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs .
COPY config config
COPY lib lib
RUN mix deps.get --only prod || true
RUN mix release

# ---- runtime image ----
FROM alpine:3.20 AS app

RUN apk add --no-cache libstdc++ ncurses openssl ca-certificates
WORKDIR /app
COPY --from=build /app/_build/prod/rel/nano_agent ./

ENV NANO_DATA_DIR=/data
# Bind to all interfaces INSIDE the container so `-p` port mapping works (the app
# defaults to loopback otherwise). Because this exposes an API that can run bash,
# set NANO_WEB_TOKEN and/or map the port to host loopback:
#   docker run -e NANO_WEB_TOKEN=secret -p 127.0.0.1:4000:4000 ...
ENV NANO_WEB_BIND=0.0.0.0
VOLUME /data
EXPOSE 4000

# Provide DEEPSEEK_API_KEY (or ANTHROPIC_API_KEY / OPENAI_API_KEY) at run time.
ENTRYPOINT ["/app/bin/nano_agent"]
CMD ["start"]
