defmodule Convoy.LoaderTest do
  use ExUnit.Case, async: true

  alias Convoy.{Loader, Compile}

  test "wat prepare loads text on the :wasm backend unchanged" do
    assert {:ok, :wasm, "(module)", "(module)"} = Loader.prepare(:wat, "(module)")
  end

  test "raw wasm bytes load as-is with a byte-size label" do
    bytes = <<0, 97, 115, 109>>
    assert {:ok, :wasm, ^bytes, display} = Loader.prepare(:wasm, bytes)
    assert display =~ "4 bytes"
  end

  test "unknown language is rejected" do
    assert {:error, msg} = Loader.prepare(:cobol, "x")
    assert msg =~ "unknown language"
  end

  test "a compiled language yields wasm bytes but keeps high-level source as display" do
    if Compile.available?(:rust) do
      src = Compile.template(:rust)
      assert {:ok, :wasm, bytes, ^src} = Loader.prepare(:rust, src)
      assert is_binary(bytes) and byte_size(bytes) > 0
    else
      assert {:error, _} = Loader.prepare(:rust, Compile.template(:rust))
    end
  end
end
