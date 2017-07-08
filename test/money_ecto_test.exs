defmodule MoneyTest.Ecto do
  use ExUnit.Case

  test "load a tuple produces a Money struct" do
    assert Money.Ecto.Composite.Type.load({100, "USD"}) == {:ok, Money.new(100, :USD)}
  end

  test "load a tuple with an unknown currency code produces an error" do
    assert Money.Ecto.Composite.Type.load({100, "ABC"}) ==
      {:error, {Cldr.UnknownCurrencyError, "Currency \"ABC\" is not known"}}
  end

  test "dump a money struct" do
    assert Money.Ecto.Composite.Type.dump(Money.new(100, :USD)) == {:ok, {Decimal.new(100), "USD"}}
  end

  test "dump a money tuple" do
    assert Money.Ecto.Composite.Type.dump({100, "USD"}) == {:ok, {100, "USD"}}
  end

  test "dump anything other than a Money struct or a 2-tuple is an error" do
    assert Money.Ecto.Composite.Type.dump(100) == :error
  end

  test "cast a money struct" do
    assert Money.Ecto.Composite.Type.cast Money.new(100, :USD) == Money.new(100, :USD)
  end

  test "cast a map with string keys and values" do
    assert Money.Ecto.Composite.Type.cast %{"currency" => "USD", "amount" => "100"} == Money.new(100, :USD)
  end

  test "cast a map with string keys and numeric amount" do
    assert Money.Ecto.Composite.Type.cast %{"currency" => "USD", "amount" => 100} == Money.new(100, :USD)
  end

  test "cast a map with string keys and invalid currency" do
    assert Money.Ecto.Composite.Type.cast(%{"currency" => "AAA", "amount" => 100}) ==
    {:error, {Cldr.UnknownCurrencyError, "Currency \"AAA\" is not known"}}
  end

  test "cast anything else is an error" do
    assert Money.Ecto.Composite.Type.cast(:atom) == :error
  end
end