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
VOLUME /data
EXPOSE 4000

# Provide ANTHROPIC_API_KEY (or OPENAI_API_KEY) at run time.
ENTRYPOINT ["/app/bin/nano_agent"]
CMD ["start"]
