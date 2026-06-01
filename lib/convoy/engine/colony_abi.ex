defmodule Convoy.Engine.ColonyAbi do
  @moduledoc """
  The wire format for the v2 **colony ABI** (see `docs/colony-v2-design.md`).

  v2 replaces the per-entity `decide` reflex with one **colony brain** the host
  calls once per tick. Because the module has zero host imports, I/O is via
  linear memory at fixed buffers the guest exposes (`inbuf`/`outbuf`):

      host: write encode_view(view) into the module's IN buffer (at inbuf())
      host: call tick(view_len) -> command_count
      host: read command_count * 16 bytes from the OUT buffer (at outbuf())
      host: decode_commands(bytes, count) -> [command]

  The format is **fixed-stride little-endian** records — trivial to decode with
  no allocator (the guest is `no_std`) and trivially bit-identical, so replays
  stay deterministic (primer §6). Forward-compat is deferred behind the header's
  implicit versioning (append fields at the end of a record + bump a version
  later). This module is the single source of truth for the layout; the in-file
  bot boilerplate (see `examples/colony.rs`) must match it byte for byte.

  ## View layout (host → guest), all little-endian

      header (28 bytes):
        tick:u32  width:u16  height:u16
        ore:u32   goods:u32  credits:u32
        n_units:u16  n_buildings:u16  n_deposits:u16  n_market:u16
      units[n_units]      — 12B: id:u32 kind:u8 x:u8 y:u8 cargo:u16 cargo_max:u16 _pad:u8
      buildings[n_bld]    — 10B: id:u32 kind:u8 x:u8 y:u8 level:u8 progress:u8 _pad:u8
      deposits[n_dep]     —  4B: x:u8 y:u8 amount:u16
      market[n_market]    — 10B: id:u32 owner:u8 x:u8 y:u8 cargo:u16 _pad:u8

  ## Command layout (guest → host)

      command — 16B: op:u8 _pad:u8 _pad:u16 target:u32 a:i32 b:i32

  `kind`/`op` enums are mirrored as module attributes below.
  """

  # Unit kinds.
  @unit_harvester 0
  @unit_hauler 1
  @unit_builder 2
  @unit_convoy 3

  # Building kinds.
  @bld_spawner 0
  @bld_refinery 1
  @bld_storage 2
  @bld_fabricator 3

  # Command ops (target = the unit/building the order applies to).
  @op_idle 0
  @op_harvest 1
  @op_move 2
  @op_transfer 3
  @op_build 4
  @op_spawn 5
  @op_upgrade 6
  @op_launch 7
  @op_defend 8
  @op_hunt 9

  @command_size 16

  def unit_kinds, do: %{harvester: @unit_harvester, hauler: @unit_hauler, builder: @unit_builder, convoy: @unit_convoy}
  def building_kinds, do: %{spawner: @bld_spawner, refinery: @bld_refinery, storage: @bld_storage, fabricator: @bld_fabricator}

  @doc """
  Serialize a colony view map to the wire format. Expects:

      %{tick:, width:, height:, ore:, goods:, credits:,
        units:      [%{id:, kind:, x:, y:, cargo:, cargo_max:}],
        buildings:  [%{id:, kind:, x:, y:, level:, progress:}],
        deposits:   [%{x:, y:, amount:}],
        market:     [%{id:, owner:, x:, y:, cargo:}]   (optional, defaults [])}
  """
  @spec encode_view(map()) :: binary()
  def encode_view(v) do
    units = Map.get(v, :units, [])
    buildings = Map.get(v, :buildings, [])
    deposits = Map.get(v, :deposits, [])
    market = Map.get(v, :market, [])

    header = <<
      v.tick::little-32,
      v.width::little-16,
      v.height::little-16,
      Map.get(v, :ore, 0)::little-32,
      Map.get(v, :goods, 0)::little-32,
      Map.get(v, :credits, 0)::little-32,
      length(units)::little-16,
      length(buildings)::little-16,
      length(deposits)::little-16,
      length(market)::little-16
    >>

    units_b =
      for u <- units, into: <<>> do
        <<u.id::little-32, u.kind::8, u.x::8, u.y::8, u.cargo::little-16, u.cargo_max::little-16, 0::8>>
      end

    bld_b =
      for b <- buildings, into: <<>> do
        <<b.id::little-32, b.kind::8, b.x::8, b.y::8, b.level::8, b.progress::8, 0::8>>
      end

    dep_b =
      for d <- deposits, into: <<>> do
        <<d.x::8, d.y::8, d.amount::little-16>>
      end

    mkt_b =
      for m <- market, into: <<>> do
        <<m.id::little-32, m.owner::8, m.x::8, m.y::8, m.cargo::little-16, 0::8>>
      end

    header <> units_b <> bld_b <> dep_b <> mkt_b
  end

  @doc """
  Decode `count` fixed-stride command records from the guest's OUT buffer.
  Returns a list of `%{op:, target:, a:, b:}` (a/b signed). Tolerant of a buffer
  shorter than `count * 16` (clamps), so a misbehaving guest can't crash the host.
  """
  @spec decode_commands(binary(), non_neg_integer()) :: [map()]
  def decode_commands(_bin, count) when count <= 0, do: []

  def decode_commands(bin, count) do
    n = min(count, div(byte_size(bin), @command_size))

    for i <- 0..(n - 1)//1 do
      off = i * @command_size
      <<_::binary-size(off), op::8, _pad::24, target::little-32, a::little-signed-32, b::little-signed-32, _::binary>> = bin
      %{op: op, target: target, a: a, b: b}
    end
  end

  @doc "Human-readable op name (for the event log / debugging)."
  def op_name(@op_idle), do: :idle
  def op_name(@op_harvest), do: :harvest
  def op_name(@op_move), do: :move
  def op_name(@op_transfer), do: :transfer
  def op_name(@op_build), do: :build
  def op_name(@op_spawn), do: :spawn
  def op_name(@op_upgrade), do: :upgrade
  def op_name(@op_launch), do: :launch
  def op_name(@op_defend), do: :defend
  def op_name(@op_hunt), do: :hunt
  def op_name(_), do: :idle
end
