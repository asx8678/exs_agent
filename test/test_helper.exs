# :live tests hit a real provider API and are excluded by default. Run them with:
#   DEEPSEEK_API_KEY=... mix test --include live
ExUnit.start(exclude: [:live])
