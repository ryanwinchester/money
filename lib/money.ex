defmodule Money do
  @moduledoc """
  Money implements a set of functions to store, retrieve and perform arithmetic
  on a %Money{} type that is composed of a currency code and a currency amount.

  Money is very opinionated in the interests of serving as a dependable library
  that can underpin accounting and financial applications.  In its initial
  release it can be expected that this contract may not be fully met.

  How is this opinion expressed:

  1. Money must always have both a amount and a currency code.

  2. The currency code must always be valid.

  3. Money arithmetic can only be performed when both operands are of the
  same currency.

  4. Money amounts are represented as a `Decimal`.

  5. Money is serialised to the database as a custom Postgres composite type
  that includes both the amount and the currency. Therefore for Ecto
  serialization Postgres is assumed as the data store. Serialization is
  entirely optional and Ecto is not a package dependency.

  6. All arithmetic functions work in fixed point decimal.  No rounding
  occurs automatically (unless expressly called out for a function).

  7. Explicit rounding obeys the rounding rules for a given currency.  The
  rounding rules are defined by the Unicode consortium in its CLDR
  repository as implemented by the hex package `ex_cldr`.  These rules
  define the number of fractional digits for a currency and the rounding
  increment where appropriate.
  """

  @typedoc """
  Money is composed of an atom representation of an ISO4217 currency code and
  a `Decimal` representation of an amount.
  """
  @type t :: %Money{amount: Decimal, currency: atom}
  defstruct amount: nil, currency: nil
  import Kernel, except: [round: 1, div: 1]

  # Default mode for rounding is :half_even, also known
  # as bankers rounding
  @default_rounding_mode :half_even

  use Application

  alias Cldr.Currency

  # See http://elixir-lang.org/docs/stable/elixir/Application.html
  # for more information on OTP Applications
  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = if start_exchange_rate_service?() do
      [supervisor(Money.ExchangeRates.Supervisor, [])]
    else
      []
    end

    opts = [strategy: :one_for_one, name: Money.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Default is to not start the exchange rate service
  defp start_exchange_rate_service? do
    get_env(:exchange_rate_service, false)
  end

  @doc """
  Returns a %Money{} struct from a tuple consistenting of a currency code and
  a currency amount.  The format of the argument is a 2-tuple where:

  * `currency_code` is an ISO4217 three-character upcased binary

  * `amount` is an integer, float or Decimal

  This function is typically called from Ecto when it's loading a %Money{}
  struct from the database.

  ## Example

      iex> Money.new({"USD", 100})
      #Money<:USD, 100>

      iex> Money.new({100, "USD"})
      #Money<:USD, 100>
  """
  @spec new({binary, number}) :: Money.t
  def new({amount, currency_code}) when is_binary(currency_code) and is_number(amount) do
    case validate_currency_code(currency_code) do
      {:error, {_exception, message}} ->
        {:error, {Money.UnknownCurrencyError, message}}
      {:ok, code} ->
        %Money{amount: Decimal.new(amount), currency: code}
    end
  end

  def new({currency_code, amount}) when is_binary(currency_code) and is_number(amount) do
    new({amount, currency_code})
  end

  @doc """
  Returns a %Money{} struct from a tuple consistenting of a currency code and
  a currency amount.  Raises an exception if the currency code is invalid.

  * `currency_code` is an ISO4217 three-character upcased binary

  * `amount` is an integer, float or Decimal

  This function is typically called from Ecto when it's loading a %Money{}
  struct from the database.

  ## Example

      iex> Money.new!({"USD", 100})
      #Money<:USD, 100>

      Money.new!({"NO!", 100})
      ** (Money.UnknownCurrencyError) Currency "NO!" is not known
          (ex_money) lib/money.ex:130: Money.new!/1
  """
  def new!({amount, currency_code}) when is_binary(currency_code) and is_number(amount) do
    case money = new(currency_code, amount) do
      {:error, {exception, message}} -> raise exception, message
      _ -> money
    end
  end

  def new!({currency_code, amount}) when is_binary(currency_code) and is_number(amount) do
    new!({amount, currency_code})
  end

  @doc """
  Returns a %Money{} struct from a currency code and a currency amount or
  an error tuple of the form `{:error, {exception, message}}`.

  * `currency_code` is an ISO4217 three-character upcased binary or atom

  * `amount` is an integer, float or Decimal

  Note that the `currency_code` and `amount` arguments can be supplied in
  either order,

  ## Examples

      iex> Money.new(:USD, 100)
      #Money<:USD, 100>

      iex> Money.new(100, :USD)
      #Money<:USD, 100>

      iex> Money.new("USD", 100)
      #Money<:USD, 100>

      iex> Money.new("thb", 500)
      #Money<:THB, 500>

      iex> Money.new(500, "thb")
      #Money<:THB, 500>

      iex> Money.new("EUR", Decimal.new(100))
      #Money<:EUR, 100>

      iex> Money.new(:XYZZ, 100)
      {:error, {Money.UnknownCurrencyError, "Currency :XYZZ is not known"}}
  """
  @spec new(number, binary) :: Money.t
  def new(amount, currency_code) when is_binary(currency_code) do
    case validate_currency_code(currency_code) do
      {:error, {_exception, message}} -> {:error, {Money.UnknownCurrencyError, message}}
      {:ok, code} -> new(code, amount)
    end
  end

  def new(currency_code, amount) when is_binary(currency_code) do
    new(amount, currency_code)
  end

  def new(amount, currency_code) when is_atom(currency_code) and is_number(amount) do
    case validate_currency_code(currency_code) do
      {:error, {_exception, message}} -> {:error, {Money.UnknownCurrencyError, message}}
      {:ok, code} -> %Money{amount: Decimal.new(amount), currency: code}
    end
  end

  def new(currency_code, amount) when is_number(amount) and is_atom(currency_code) do
    new(amount, currency_code)
  end

  def new(%Decimal{} = amount, currency_code) when is_atom(currency_code) do
    case validate_currency_code(currency_code) do
      {:error, {_exception, message}} -> {:error, {Money.UnknownCurrencyError, message}}
      {:ok, code} -> %Money{amount: amount, currency: code}
    end
  end

  def new(currency_code, %Decimal{} = amount) when is_atom(currency_code) do
    new(amount, currency_code)
  end

  @doc """
  Returns a %Money{} struct from a currency code and a currency amount. Raises an
  exception if the current code is invalid.

  * `currency_code` is an ISO4217 three-character upcased binary or atom

  * `amount` is an integer, float or Decimal

  ## Examples

      Money.new!(:XYZZ, 100)
      ** (Money.UnknownCurrencyError) Currency :XYZZ is not known
        (ex_money) lib/money.ex:177: Money.new!/2
  """
  def new!(amount, currency_code) when (is_binary(currency_code) or is_atom(currency_code)) do
    case money = new(amount, currency_code) do
      {:error, {exception, message}} -> raise exception, message
      _ -> money
    end
  end

  def new!(currency_code, amount)
  when (is_binary(currency_code) or is_atom(currency_code)) and is_number(amount) do
    new!(amount, currency_code)
  end

  def new!(currency_code, %Decimal{} = amount)
  when is_binary(currency_code) or is_atom(currency_code) do
    new!(amount, currency_code)
  end

  def new!(%Decimal{} = amount, currency_code)
  when is_binary(currency_code) or is_atom(currency_code) do
    new!(amount, currency_code)
  end

  @doc """
  Returns a formatted string representation of a `Money{}`.

  Formatting is performed according to the rules defined by CLDR. See
  `Cldr.Number.to_string/2` for formatting options.  The default is to format
  as a currency which applies the appropriate rounding and fractional digits
  for the currency.

  ## Examples

      iex> Money.to_string Money.new(:USD, 1234)
      "$1,234.00"

      iex> Money.to_string Money.new(:JPY, 1234)
      "¥1,234"

      iex> Money.to_string Money.new(:THB, 1234)
      "THB1,234.00"

      iex> Money.to_string Money.new(:USD, 1234), format: :long
      "1,234 US dollars"
  """
  def to_string(%Money{} = money, options \\ []) do
    options = merge_options(options, [currency: money.currency])
    Cldr.Number.to_string(money.amount, options)
  end

  @doc """
  Returns the amount part of a `Money` type as a `Decimal`

  ## Example

      iex> m = Money.new("USD", 100)
      iex> Money.to_decimal(m)
      #Decimal<100>
  """
  def to_decimal(%Money{amount: amount}) do
    amount
  end

  @doc """
  Add two `Money` values.

  ## Example

      iex> Money.add Money.new(:USD, 200), Money.new(:USD, 100)
      {:ok, Money.new(:USD, 300)}

      iex> Money.add Money.new(:USD, 200), Money.new(:AUD, 100)
      {:error, {ArgumentError, "Cannot add monies with different currencies. " <>
        "Received :USD and :AUD."}}
  """
  @spec add(Money.t, Money.t) :: Money.t
  def add(%Money{currency: same_currency, amount: amount_a}, %Money{currency: same_currency, amount: amount_b}) do
    {:ok, %Money{currency: same_currency, amount: Decimal.add(amount_a, amount_b)}}
  end

  def add(%Money{currency: code_a}, %Money{currency: code_b}) do
    {:error, {ArgumentError, "Cannot add monies with different currencies. " <>
      "Received #{inspect code_a} and #{inspect code_b}."}}
  end

  @doc """
  Add two `Money` values and raise on error.

  ## Examples

      iex> Money.add! Money.new(:USD, 200), Money.new(:USD, 100)
      #Money<:USD, 300>

      Money.add! Money.new(:USD, 200), Money.new(:CAD, 500)
      ** (ArgumentError) Cannot add two %Money{} with different currencies. Received :USD and :CAD.
  """
  def add!(%Money{} = a, %Money{} = b) do
    case add(a, b) do
      {:ok, result} -> result
      {:error, {exception, message}} -> raise exception, message
    end
  end

  @doc """
  Subtract one `Money` value struct from another.

  Returns either `{:ok, money}` or `{:error, reason}`.

  ## Example

      iex> Money.sub Money.new(:USD, 200), Money.new(:USD, 100)
      {:ok, Money.new(:USD, 100)}
  """
  def sub(%Money{currency: same_currency, amount: amount_a}, %Money{currency: same_currency, amount: amount_b}) do
    {:ok, %Money{currency: same_currency, amount: Decimal.sub(amount_a, amount_b)}}
  end

  def sub(%Money{currency: code_a}, %Money{currency: code_b}) do
    {:error, {ArgumentError, "Cannot subtract two %Money{} with different currencies. " <>
      "Received #{inspect code_a} and #{inspect code_b}."}}
  end

  @doc """
  Subtract one `Money` value struct from another and raise on error.

  Returns either `{:ok, money}` or `{:error, reason}`.

  ## Examaples

      iex> Money.sub! Money.new(:USD, 200), Money.new(:USD, 100)
      #Money<:USD, 100>

      Money.sub! Money.new(:USD, 200), Money.new(:CAD, 500)
      ** (ArgumentError) Cannot subtract monies with different currencies. Received :USD and :CAD.
  """
  def sub!(%Money{} = a, %Money{} = b) do
    case sub(a, b) do
      {:ok, result} -> result
      {:error, {exception, message}} -> raise exception, message
    end
  end

  @doc """
  Multiply a `Money` value by a number.

  * `money` is a %Money{} struct

  * `number` is an integer or float

  > Note that multipling one %Money{} by another is not supported.

  Returns either `{:ok, money}` or `{:error, reason}`.

  ## Example

      iex> Money.mult(Money.new(:USD, 200), 2)
      {:ok, Money.new(:USD, 400)}

      iex> Money.mult(Money.new(:USD, 200), "xx")
      {:error, {ArgumentError, "Cannot multiply money by \\"xx\\""}}
  """
  @spec mult(Money.t, number) :: Money.t
  def mult(%Money{currency: code, amount: amount}, number) when is_number(number) do
    {:ok, %Money{currency: code, amount: Decimal.mult(amount, Decimal.new(number))}}
  end

  def mult(%Money{}, other) do
    {:error, {ArgumentError, "Cannot multiply money by #{inspect other}"}}
  end

  @doc """
  Multiply a `Money` value by a number and raise on error.

  ## Examples

      iex> Money.mult!(Money.new(:USD, 200), 2)
      #Money<:USD, 400>

      Money.mult!(Money.new(:USD, 200), :invalid)
      ** (ArgumentError) Cannot multiply money by :invalid
  """
  def mult!(%Money{} = money, number) do
    case mult(money, number) do
      {:ok, result} -> result
      {:error, {exception, message}} -> raise exception, message
    end
  end

  @doc """
  Divide a `Money` value by a number.

  * `money` is a %Money{} struct

  * `number` is an integer or float

  > Note that dividing one %Money{} by another is not supported.

  ## Example

      iex> Money.div Money.new(:USD, 200), 2
      {:ok, Money.new(:USD, 100)}

      iex> Money.div(Money.new(:USD, 200), "xx")
      {:error, {ArgumentError, "Cannot divide money by \\"xx\\""}}
  """
  @spec div(Money.t, number) :: Money.t
  def div(%Money{currency: code, amount: amount}, number) when is_number(number) do
    {:ok, %Money{currency: code, amount: Decimal.div(amount, Decimal.new(number))}}
  end

  def div(%Money{}, other) do
    {:error, {ArgumentError, "Cannot divide money by #{inspect other}"}}
  end

  @doc """
  Divide a `Money` value by a number and raise on error.

  ## Examples

      iex> Money.div Money.new(:USD, 200), 2
      {:ok, Money.new(:USD, 100)}

      Money.div(Money.new(:USD, 200), "xx")
      ** (ArgumentError) "Cannot divide money by \\"xx\\""]}}
  """
  def div!(%Money{} = money, number) do
    case Money.div(money, number) do
      {:ok, result} -> result
      {:error, {exception, message}} -> raise exception, message
    end
  end

  @doc """
  Returns a boolean indicating if two `Money` values are equal

  ## Example

      iex> Money.equal? Money.new(:USD, 200), Money.new(:USD, 200)
      true

      iex> Money.equal? Money.new(:USD, 200), Money.new(:USD, 100)
      false
  """
  @spec equal?(Money.t, Money.t) :: boolean
  def equal?(%Money{currency: same_currency, amount: amount_a}, %Money{currency: same_currency, amount: amount_b}) do
    Decimal.equal?(amount_a, amount_b)
  end

  def equal?(_, _) do
    false
  end

  @doc """
  Compares two `Money` values numerically. If the first number is greater
  than the second :gt is returned, if less than :lt is returned, if both
  numbers are equal :eq is returned.

  ## Examples

      iex> Money.cmp Money.new(:USD, 200), Money.new(:USD, 100)
      :gt

      iex> Money.cmp Money.new(:USD, 200), Money.new(:USD, 200)
      :eq

      iex> Money.cmp Money.new(:USD, 200), Money.new(:USD, 500)
      :lt

      iex> Money.cmp Money.new(:USD, 200), Money.new(:CAD, 500)
      {:error,
       {ArgumentError,
        "Cannot compare monies with different currencies. Received :USD and :CAD."}}
  """
  def cmp(%Money{currency: same_currency, amount: amount_a}, %Money{currency: same_currency, amount: amount_b}) do
    Decimal.cmp(amount_a, amount_b)
  end

  def cmp(%Money{currency: code_a}, %Money{currency: code_b}) do
    {:error, {ArgumentError, "Cannot compare monies with different currencies. " <>
      "Received #{inspect code_a} and #{inspect code_b}."}}
  end

  @doc """
  Compares two `Money` values numerically and raises on error.

  ## Examples

      Money.cmp! Money.new(:USD, 200), Money.new(:CAD, 500)
      ** (ArgumentError) Cannot compare monies with different currencies. Received :USD and :CAD.
  """
  def cmp!(%Money{} = money_1, %Money{} = money_2) do
    case cmp(money_1, money_2) do
      {:error, {exception, reason}} -> raise exception, reason
      result -> result
    end
  end

  @doc """
  Compares two `Money` values numerically. If the first number is greater
  than the second #Integer<1> is returned, if less than Integer<-1> is
  returned. Otherwise, if both numbers are equal Integer<0> is returned.

  ## Examples

      iex> Money.compare Money.new(:USD, 200), Money.new(:USD, 100)
      1

      iex> Money.compare Money.new(:USD, 200), Money.new(:USD, 200)
      0

      iex> Money.compare Money.new(:USD, 200), Money.new(:USD, 500)
      -1

      iex> Money.compare Money.new(:USD, 200), Money.new(:CAD, 500)
      {:error,
       {ArgumentError,
        "Cannot compare monies with different currencies. Received :USD and :CAD."}}
  """
  def compare(%Money{currency: same_currency, amount: amount_a}, %Money{currency: same_currency, amount: amount_b}) do
    amount_a
    |> Decimal.compare(amount_b)
    |> Decimal.to_integer
  end

  def compare(%Money{currency: code_a}, %Money{currency: code_b}) do
    {:error, {ArgumentError, "Cannot compare monies with different currencies. " <>
      "Received #{inspect code_a} and #{inspect code_b}."}}
  end

  @doc """
  Compares two `Money` values numerically and raises on error.

  ## Examples

      Money.compare! Money.new(:USD, 200), Money.new(:CAD, 500)
      ** (ArgumentError) Cannot compare monies with different currencies. Received :USD and :CAD.
  """
  def compare!(%Money{} = money_1, %Money{} = money_2) do
    case compare(money_1, money_2) do
      {:error, {exception, reason}} -> raise exception, reason
      result -> result
    end
  end

  @doc """
  Split a `Money` value into a number of parts maintaining the currency's
  precision and rounding and ensuring that the parts sum to the original
  amount.

  * `money` is a `%Money{}` struct

  * `parts` is an integer number of parts into which the `money` is split

  Returns a tuple `{dividend, remainder}` as the function result
  derived as follows:

  1. Round the money amount to the required currency precision using
  `Money.round/1`

  2. Divide the result of step 1 by the integer divisor

  3. Round the result of the division to the precision of the currency
  using `Money.round/1`

  4. Return two numbers: the result of the division and any remainder
  that could not be applied given the precision of the currency.

  ## Examples

      Money.split Money.new(123.5, :JPY), 3
      {¥41, ¥1}

      Money.split Money.new(123.4, :JPY), 3
      {¥41, ¥0}

      Money.split Money.new(123.7, :USD), 9
      {$13.74, $0.04}
  """
  def split(%Money{} = money, parts) when is_integer(parts) do
    rounded_money = Money.round(money)

    div =
      rounded_money
      |> Money.div!(parts)
      |> round

    remainder = sub!(rounded_money, mult!(div, parts))
    {div, remainder}
  end

  @doc """
  Round a `Money` value into the acceptable range for the defined currency.

  * `money` is a `%Money{}` struct

  * `opts` is a keyword list with the following keys:

    * `:rounding_mode` that defines how the number will be rounded.  See
    `Decimal.Context`.  The default is `:half_even` which is also known
    as "banker's rounding"

    * `:cash` which determines whether the rounding is being applied to
    an accounting amount or a cash amount.  Some currencies, such as the
    :AUD and :CHF have a cash unit increment minimum which requires
    a different rounding increment to an arbitrary accounting amount. The
    default is `false`.

  There are two kinds of rounding applied:

  1.  Round to the appropriate number of fractional digits

  2. Apply an appropriate rounding increment.  Most currencies
  round to the same precision as the number of decimal digits, but some
  such as :AUD and :CHF round to a minimum such as 0.05 when its a cash
  amount.

  ## Examples

      iex> Money.round Money.new(123.7456, :CHF), cash: true
      #Money<:CHF, 125>

      iex> Money.round Money.new(123.7456, :CHF)
      #Money<:CHF, 123.75>

      Money.round Money.new(123.7456, :JPY)
      #Money<:JPY, 124>
  """
  def round(%Money{} = money, opts \\ []) do
    money
    |> round_to_decimal_digits(opts)
    |> round_to_nearest(opts)
  end

  defp round_to_decimal_digits(%Money{currency: code, amount: amount}, opts) do
    rounding_mode = Keyword.get(opts, :rounding_mode, @default_rounding_mode)
    currency = Currency.for_code(code)
    rounding = if opts[:cash], do: currency.cash_digits, else: currency.digits
    rounded_amount = Decimal.round(amount, rounding, rounding_mode)
    %Money{currency: code, amount: rounded_amount}
  end

  defp round_to_nearest(%Money{currency: code} = money, opts) do
    currency  = Currency.for_code(code)
    increment = if opts[:cash], do: currency.cash_rounding, else: currency.rounding
    do_round_to_nearest(money, increment, opts)
  end

  defp do_round_to_nearest(money, 0, _opts) do
    money
  end

  defp do_round_to_nearest(money, increment, opts) do
    rounding_mode = Keyword.get(opts, :rounding_mode, @default_rounding_mode)
    rounding = Decimal.new(increment)

    rounded_amount =
      money.amount
      |> Decimal.div(rounding)
      |> Decimal.round(0, rounding_mode)
      |> Decimal.mult(rounding)

    %Money{currency: money.currency, amount: rounded_amount}
  end

  @doc """
  Convert `money` from one currency to another.

  * `money` is a %Money{} struct

  * `to_currency` is a valid currency code into which the `money` is converted

  * `rates` is a `Map` of currency rates where the map key is an upcase
  atom and the value is a Decimal conversion factor.  The default is the
  latest available exchange rates returned from `Money.ExchangeRates.latest_rates()`

  ## Examples

      Money.to_currency(Money.new(:USD, 100), :AUD, %{USD: Decimal.new(1), AUD: Decimal.new(0.7345)})
      {:ok, #Money<:AUD, 73.4500>}

      iex> Money.to_currency Money.new(:USD, 100) , :AUDD, %{USD: Decimal.new(1), AUD: Decimal.new(0.7345)}
      {:error, {Cldr.UnknownCurrencyError, "Currency :AUDD is not known"}}

      iex> Money.to_currency Money.new(:USD, 100) , :CHF, %{USD: Decimal.new(1), AUD: Decimal.new(0.7345)}
      {:error, {Money.ExchangeRateError, "No exchange rate is available for currency :CHF"}}
  """
  def to_currency(money, to_currency, rates \\ Money.ExchangeRates.latest_rates())

  def to_currency(%Money{currency: currency} = money, to_currency, _rates)
  when currency == to_currency do
    {:ok, money}
  end

  def to_currency(%Money{currency: currency} = money, to_currency, %{} = rates)
  when is_atom(to_currency) or is_binary(to_currency) do
    with {:ok, to_code} <- Money.validate_currency_code(to_currency) do
      if currency == to_code, do: money, else: to_currency(money, to_currency, {:ok, rates})
    else
      {:error, _} = error -> error
    end
  end

  def to_currency(%Money{currency: from_currency, amount: amount}, to_currency, {:ok, rates})
  when is_atom(to_currency) or is_binary(to_currency) do
    with {:ok, currency_code} <- Money.validate_currency_code(to_currency),
         {:ok, base_rate} <- get_rate(from_currency, rates),
         {:ok, conversion_rate} <- get_rate(currency_code, rates) do

      converted_amount =
        amount
        |> Decimal.div(base_rate)
        |> Decimal.mult(conversion_rate)

      {:ok, Money.new(to_currency, converted_amount)}
    else
      {:error, _} = error -> error
    end
  end

  def to_currency(_money, _to_currency, {:error, reason}) do
    {:error, reason}
  end

  @doc """
  Convert `money` from one currency to another and raises on error

  ## Examples

      iex> Money.to_currency! Money.new(:USD, 100) , :AUD, %{USD: Decimal.new(1), AUD: Decimal.new(0.7345)}
      #Money<:AUD, 73.4500>

      Money.to_currency! Money.new(:USD, 100) , :ZZZ, %{USD: Decimal.new(1), AUD: Decimal.new(0.7345)}
      ** (Cldr.UnknownCurrencyError) Currency :ZZZ is not known
  """
  def to_currency!(%Money{} = money, currency) do
    money
    |> to_currency(currency)
    |> do_to_currency!
  end

  def to_currency!(%Money{} = money, currency, rates) do
    money
    |> to_currency(currency, rates)
    |> do_to_currency!
  end

  defp do_to_currency!(result) do
    case result do
      {:ok, converted} -> converted
      {:error, {exception, reason}} -> raise exception, reason
    end
  end

  def get_env(key, default \\ nil) do
    case env = Application.get_env(:ex_money, key, default) do
      {:system, env_key} ->
        System.get_env(env_key)
      _ ->
        env
    end
  end

  ## Helpers

  defp get_rate(currency, rates) do
    if rate = rates[currency] do
      {:ok, rate}
    else
      {:error, {Money.ExchangeRateError, "No exchange rate is available for currency #{inspect currency}"}}
    end
  end

  def validate_currency_code(currency_code) do
    case Currency.validate_currency_code(currency_code) do
      {:error, _} = error -> error
      {:ok, code} -> {:ok, code}
    end
  end

  defp merge_options(options, required) do
    Keyword.merge(options, required, fn _k, _v1, v2 -> v2 end)
  end

  defimpl String.Chars do
    def to_string(v) do
      Money.to_string(v)
    end
  end

  defimpl Inspect, for: Money do
    def inspect(money, _opts) do
      "#Money<#{inspect money.currency}, #{Decimal.to_string(money.amount)}>"
    end
  end

  if Code.ensure_compiled?(Phoenix.HTML.Safe) do
    defimpl Phoenix.HTML.Safe, for: Money do
      def to_iodata(money) do
        Phoenix.HTML.Safe.to_iodata(to_string(money))
      end
    end
  end
end
