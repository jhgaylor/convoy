# Start from a clean persistence dir so leftover snapshots can't leak between
# runs (tests use an isolated tmp dir; see config/test.exs).
File.rm_rf(Convoy.Persistence.dir())

ExUnit.start()
