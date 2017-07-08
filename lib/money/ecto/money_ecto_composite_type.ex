defmodule Money.Ecto.Composite.Type do
  @moduledoc """
  Implements the Ecto.Type behaviour for a user-defined Postgres composite type
  called `:money_with_currency`.

  This is the preferred option for Postgres database since the serialized money
  amount is stored as a number,
  """

  if Code.ensure_loaded?(Ecto.Type) do
    @behaviour Ecto.Type

    def type do
      :money_with_currency
    end

    def blank?(_) do
      false
    end

    # When loading from the database
    def load({amount, currency}) do
      with {:ok, currency_code} <- Money.validate_currency_code(currency) do
        {:ok, Money.new(amount, currency_code)}
      else
        error -> error
      end
    end

    # Dumping to the database.  We make the assumption that
    # since we are dumping from %Money{} structs that the
    # data is ok
    def dump(%Money{} = money) do
      {:ok, {money.amount, to_string(money.currency)}}
    end

    def dump({amount, currency})
    when (is_binary(currency) or is_atom(currency)) and is_number(amount) do
      with {:ok, currency_code} <- Money.validate_currency_code(currency) do
        {:ok, {amount, to_string(currency_code)}}
      else
        error -> error
      end
    end

    def dump(_) do
      :error
    end

    # Casting in changesets
    def cast(%Money{} = money) do
      {:ok, money}
    end

    def cast({amount, currency} = money)
    when (is_binary(currency) or is_atom(currency)) and is_number(amount) do
      {:ok, Money.new(money)}
    end

    def cast(%{"currency" => currency, "amount" => amount})
    when (is_binary(currency) or is_atom(currency)) and is_number(amount) do
      with decimal_amount <- Decimal.new(amount),
           {:ok, currency_code} <- Money.validate_currency_code(currency) do
        {:ok, Money.new(decimal_amount, currency_code)}
      else
        error -> error
      end
    end

    def cast(%{"currency" => currency, "amount" => amount})
    when (is_binary(currency) or is_atom(currency)) and is_binary(amount) do
      with {:ok, amount} <- Decimal.parse(amount),
           {:ok, currency_code} <- Money.validate_currency_code(currency) do
        {:ok, Money.new(amount, currency_code)}
      else
        error -> error
      end
    end

    def cast(_money) do
      :error
    end
  end
end